class SandboxManager
  DATA_DIR = ENV.fetch("SANDCASTLE_DATA_DIR", "/data")
  SANDBOX_IMAGE = "sandcastle-sandbox"

  class Error < StandardError; end

  def create(user:, name:, image: SANDBOX_IMAGE, persistent: false, tailscale: nil)
    wants_tailscale = user.tailscale_configured? && tailscale != false

    sandbox = user.sandboxes.build(
      name: name,
      image: image,
      status: "pending",
      persistent_volume: persistent,
      tailscale: wants_tailscale
    )

    if persistent
      sandbox.volume_path = "#{DATA_DIR}/sandboxes/#{sandbox.full_name}/vol"
    end

    sandbox.save!

    cloud_init = build_cloud_init(user: user, sandbox: sandbox, tailscale: wants_tailscale)
    devices = build_devices(user: user, sandbox: sandbox)

    incus.create_instance(
      name: sandbox.full_name,
      source: { type: "image", alias: image },
      config: {
        "user.user-data" => cloud_init,
        "security.nesting" => "true",
        "security.syscalls.intercept.mknod" => "true",
        "security.syscalls.intercept.setxattr" => "true"
      },
      profiles: [ "default", "sandcastle" ]
    )

    # Devices must be applied after creation — Incus ignores them in the create request
    incus.update_instance(sandbox.full_name, devices: devices)

    incus.change_state(sandbox.full_name, action: "start")
    sandbox.update!(container_id: sandbox.full_name, status: "running")

    sandbox
  rescue IncusClient::Error => e
    # Clean up partial Incus instance to avoid blocking future creates
    begin
      incus.delete_instance(sandbox.full_name)
    rescue IncusClient::Error
      # Instance may not exist or already be gone
    end
    sandbox&.update(status: "destroyed") if sandbox&.persisted?
    raise Error, "Failed to create instance: #{e.message}"
  end

  def destroy(sandbox:, keep_volume: false)
    if sandbox.container_id.present?
      begin
        incus.change_state(sandbox.container_id, action: "stop", force: true)
      rescue IncusClient::NotFoundError
        # Instance already gone
      rescue IncusClient::Error
        # May already be stopped
      end

      begin
        incus.delete_instance(sandbox.container_id)
      rescue IncusClient::NotFoundError
        # Instance already gone
      end
    end

    unless keep_volume
      FileUtils.rm_rf(sandbox.volume_path) if sandbox.volume_path.present?
    end

    sandbox.update!(status: "destroyed", container_id: nil)
  end

  def start(sandbox:)
    raise Error, "Sandbox is destroyed" if sandbox.status == "destroyed"
    return sandbox if sandbox.status == "running"

    incus.change_state(sandbox.container_id, action: "start")
    sandbox.update!(status: "running")
    sandbox
  rescue IncusClient::NotFoundError
    sandbox.update!(status: "destroyed", container_id: nil)
    raise Error, "Instance not found — sandbox must be recreated"
  end

  def stop(sandbox:)
    return sandbox if sandbox.status == "stopped"

    incus.change_state(sandbox.container_id, action: "stop", timeout: 10)
    sandbox.update!(status: "stopped")
    sandbox
  rescue IncusClient::NotFoundError
    sandbox.update!(status: "destroyed", container_id: nil)
    raise Error, "Instance not found"
  end

  def status(sandbox:)
    return { state: "destroyed" } if sandbox.container_id.blank?

    state = incus.get_instance_state(sandbox.container_id)
    {
      state: state["status"]&.downcase,
      running: state["status"] == "Running",
      pid: state["pid"]
    }
  rescue IncusClient::NotFoundError
    { state: "not_found" }
  end

  def snapshot(sandbox:, name: nil)
    raise Error, "Sandbox has no running instance" if sandbox.container_id.blank?

    name ||= Date.today.iso8601

    incus.create_snapshot(sandbox.container_id, snapshot_name: name)

    {
      name: name,
      sandbox: sandbox.name,
      created_at: Time.current
    }
  rescue IncusClient::Error => e
    raise Error, "Failed to create snapshot: #{e.message}"
  end

  def list_snapshots(user:)
    user.sandboxes.active.where.not(container_id: nil).flat_map do |sandbox|
      snapshots = incus.list_snapshots(sandbox.container_id)
      snapshots.map do |snap|
        snap_name = snap["name"]
        {
          name: snap_name,
          sandbox: sandbox.name,
          created_at: snap["created_at"] ? Time.parse(snap["created_at"]) : nil
        }
      end
    rescue IncusClient::NotFoundError
      []
    end
  rescue IncusClient::Error => e
    raise Error, "Failed to list snapshots: #{e.message}"
  end

  def destroy_snapshot(user:, name:, sandbox_name: nil)
    target = find_snapshot_sandbox(user: user, snapshot_name: name, sandbox_name: sandbox_name)
    incus.delete_snapshot(target[:sandbox].container_id, name)
  rescue IncusClient::NotFoundError
    raise Error, "Snapshot '#{name}' not found"
  rescue IncusClient::Error => e
    raise Error, "Failed to destroy snapshot: #{e.message}"
  end

  def restore(sandbox:, snapshot_name:)
    user = sandbox.user
    instance_name = sandbox.container_id

    # Verify snapshot exists
    incus.get_snapshot(instance_name, snapshot_name)

    # Stop the instance
    begin
      incus.change_state(instance_name, action: "stop", force: true)
    rescue IncusClient::Error
      # May already be stopped
    end

    # Copy from snapshot to a temp instance
    temp_name = "#{instance_name}-restore-#{SecureRandom.hex(4)}"
    incus.copy_instance(instance_name, temp_name, snapshot_name: snapshot_name)

    # Delete original
    incus.delete_instance(instance_name)

    # Rename temp to original
    incus.rename_instance(temp_name, instance_name)

    # Re-attach devices (copy may not preserve instance-specific devices)
    devices = build_devices(user: user, sandbox: sandbox)
    incus.update_instance(instance_name, devices: devices)

    # Start it
    incus.change_state(instance_name, action: "start")
    sandbox.update!(status: "running")

    # Update SSH key in case it changed since snapshot
    update_ssh_key(sandbox: sandbox)

    sandbox
  rescue IncusClient::NotFoundError
    raise Error, "Snapshot '#{snapshot_name}' not found"
  rescue IncusClient::Error => e
    raise Error, "Failed to restore snapshot: #{e.message}"
  end

  def connect_info(sandbox:)
    host = ENV.fetch("SANDCASTLE_HOST", "localhost")
    info = {
      host: host,
      port: sandbox.ssh_port,
      user: sandbox.user.name,
      command: sandbox.connect_command(host: host)
    }

    if sandbox.tailscale? && sandbox.status == "running"
      ts_ip = tailscale_ip(sandbox: sandbox)
      if ts_ip
        info[:tailscale_ip] = ts_ip
        info[:tailscale_command] = "ssh #{sandbox.user.name}@#{ts_ip}"
      end
    end

    info
  end

  def tailscale_ip(sandbox:)
    return nil unless sandbox.tailscale? && sandbox.container_id.present?

    result = incus.exec(sandbox.container_id, command: [ "tailscale", "ip", "--4" ])
    result[:stdout]&.strip.presence
  rescue IncusClient::Error
    nil
  end

  private

  def incus
    @incus ||= IncusClient.new
  end

  def build_cloud_init(user:, sandbox:, tailscale: false)
    runcmd = [
      "chown -R #{user.name}:#{user.name} /home/#{user.name}",
      "chown #{user.name}:#{user.name} /workspace 2>/dev/null || true",
      "ssh-keygen -A",
      "systemctl enable ssh",
      "systemctl start ssh",
      "systemctl enable docker",
      "systemctl start docker"
    ]

    if tailscale
      runcmd << "systemctl start tailscaled"
      runcmd << "tailscale up --authkey=#{user.tailscale_auth_key} --hostname=#{sandbox.full_name} --ssh"
    end

    runcmd_yaml = runcmd.map { |cmd| "    - #{cmd}" }.join("\n")

    <<~CLOUD_INIT
      #cloud-config
      users:
        - name: #{user.name}
          groups: sudo, docker
          shell: /bin/bash
          sudo: ALL=(ALL) NOPASSWD:ALL
          ssh_authorized_keys:
            - #{user.ssh_public_key}

      write_files:
        - path: /home/#{user.name}/.ssh/authorized_keys
          permissions: '0600'
          owner: #{user.name}:#{user.name}
          content: |
            #{user.ssh_public_key}

      runcmd:
    #{runcmd_yaml}
    CLOUD_INIT
  end

  def build_devices(user:, sandbox:)
    home_path = "#{DATA_DIR}/users/#{user.name}/home"
    FileUtils.mkdir_p(home_path)

    devices = {
      "ssh" => {
        "type" => "proxy",
        "listen" => "tcp:0.0.0.0:#{sandbox.ssh_port}",
        "connect" => "tcp:127.0.0.1:22"
      },
      "home" => {
        "type" => "disk",
        "source" => home_path,
        "path" => "/home/#{user.name}",
        "shift" => "true"
      }
    }

    if sandbox.persistent_volume && sandbox.volume_path
      FileUtils.mkdir_p(sandbox.volume_path)
      devices["workspace"] = {
        "type" => "disk",
        "source" => sandbox.volume_path,
        "path" => "/workspace",
        "shift" => "true"
      }
    end

    devices
  end

  def update_ssh_key(sandbox:)
    user = sandbox.user
    return unless user.ssh_public_key.present?

    ssh_dir = "/home/#{user.name}/.ssh"
    incus.exec(sandbox.container_id, command: [ "mkdir", "-p", ssh_dir ])
    incus.push_file(
      sandbox.container_id,
      path: "#{ssh_dir}/authorized_keys",
      content: user.ssh_public_key,
      mode: "0600"
    )
    # Fix ownership — lookup UID inside container
    incus.exec(sandbox.container_id, command: [
      "chown", "-R", "#{user.name}:#{user.name}", ssh_dir
    ])
  rescue IncusClient::Error
    # Non-fatal: cloud-init should have set this up
  end

  def find_snapshot_sandbox(user:, snapshot_name:, sandbox_name: nil)
    sandboxes = user.sandboxes.active.where.not(container_id: nil)

    if sandbox_name
      sandbox = sandboxes.find_by!(name: sandbox_name)
      return { sandbox: sandbox }
    end

    # Search all active sandboxes for this snapshot
    sandboxes.each do |sandbox|
      snapshots = incus.list_snapshots(sandbox.container_id)
      if snapshots.any? { |s| s["name"] == snapshot_name }
        return { sandbox: sandbox }
      end
    rescue IncusClient::NotFoundError
      next
    end

    raise Error, "Snapshot '#{snapshot_name}' not found in any active sandbox"
  end
end
