class SandboxManager
  DATA_DIR = ENV.fetch("SANDCASTLE_DATA_DIR", "/data")
  DEFAULT_IMAGE = "ghcr.io/thieso2/sandcastle-sandbox:latest"

  class Error < StandardError; end

  def create(user:, name:, image: DEFAULT_IMAGE, persistent: false, tailscale: false, mount_home: false, data_path: nil, temporary: false)
    sandbox = user.sandboxes.build(
      name: name,
      image: image,
      status: "pending",
      persistent_volume: persistent,
      mount_home: mount_home,
      data_path: data_path,
      temporary: temporary
    )

    if persistent
      sandbox.volume_path = "#{DATA_DIR}/sandboxes/#{sandbox.full_name}/vol"
    end

    sandbox.save!

    ensure_image(image)
    ensure_mount_dirs(user, sandbox)

    container = Docker::Container.create(
      "name" => sandbox.full_name,
      "Image" => image,
      "Hostname" => sandbox.full_name,
      "Env" => [
        "SANDCASTLE_USER=#{user.name}",
        "SANDCASTLE_SSH_KEY=#{user.ssh_public_key}"
      ],
      "HostConfig" => {
        "Runtime" => container_runtime,
        "PortBindings" => {
          "22/tcp" => [ { "HostPort" => sandbox.ssh_port.to_s } ]
        },
        "Binds" => volume_binds(user, sandbox),
        "RestartPolicy" => { "Name" => "unless-stopped" }
      }
    )

    container.start
    container.refresh!
    raise Error, "Container failed to start (state: #{container.json.dig("State", "Status")})" unless container.json.dig("State", "Running")
    sandbox.update!(container_id: container.id, status: "running")

    if (tailscale || user.tailscale_auto_connect?) && user.tailscale_enabled?
      TailscaleManager.new.connect_sandbox(sandbox: sandbox)
    end

    sandbox
  rescue Docker::Error::DockerError => e
    sandbox&.update(status: "destroyed") if sandbox&.persisted?
    raise Error, "Failed to create container: #{e.message}"
  end

  def destroy(sandbox:, keep_volume: false)
    begin
      TerminalManager.new.close(sandbox: sandbox)
    rescue TerminalManager::Error, Docker::Error::DockerError
      # best-effort terminal cleanup
    end

    RouteManager.new.remove_all_routes(sandbox: sandbox) if sandbox.routed?

    if sandbox.tailscale?
      TailscaleManager.new.disconnect_sandbox(sandbox: sandbox)
    end

    if sandbox.container_id.present?
      begin
        container = Docker::Container.get(sandbox.container_id)
        container.stop(t: 5) rescue nil
        container.delete(force: true)
      rescue Docker::Error::NotFoundError
        # Container already gone
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

    container = Docker::Container.get(sandbox.container_id)
    container.start
    sandbox.update!(status: "running")

    RouteManager.new.reconnect_routes(sandbox: sandbox) if sandbox.routed?

    sandbox
  rescue Docker::Error::NotFoundError
    sandbox.update!(status: "destroyed", container_id: nil)
    raise Error, "Container not found — sandbox must be recreated"
  end

  def stop(sandbox:)
    return sandbox if sandbox.status == "stopped"

    begin
      TerminalManager.new.close(sandbox: sandbox)
    rescue TerminalManager::Error, Docker::Error::DockerError
      # best-effort terminal cleanup
    end

    RouteManager.new.suspend_routes(sandbox: sandbox) if sandbox.routed?

    container = Docker::Container.get(sandbox.container_id)
    container.stop(t: 10)
    sandbox.update!(status: "stopped")
    sandbox
  rescue Docker::Error::NotFoundError
    sandbox.update!(status: "destroyed", container_id: nil)
    raise Error, "Container not found"
  end

  def status(sandbox:)
    return { state: "destroyed" } if sandbox.container_id.blank?

    container = Docker::Container.get(sandbox.container_id)
    info = container.json
    {
      state: info.dig("State", "Status"),
      running: info.dig("State", "Running"),
      started_at: info.dig("State", "StartedAt"),
      pid: info.dig("State", "Pid")
    }
  rescue Docker::Error::NotFoundError
    { state: "not_found" }
  end

  def snapshot(sandbox:, name: nil)
    raise Error, "Sandbox has no running container" if sandbox.container_id.blank?

    name ||= Date.today.iso8601
    user = sandbox.user
    repo = "sc-snap-#{user.name}"

    container = Docker::Container.get(sandbox.container_id)
    image = container.commit(
      repo: repo,
      tag: name,
      comment: "sandbox:#{sandbox.name}"
    )

    {
      name: name,
      image: "#{repo}:#{name}",
      sandbox: sandbox.name,
      created_at: Time.current
    }
  rescue Docker::Error::DockerError => e
    raise Error, "Failed to create snapshot: #{e.message}"
  end

  def list_snapshots(user:)
    repo_prefix = "sc-snap-#{user.name}"

    Docker::Image.all.each_with_object([]) do |img, result|
      repo_tags = img.info["RepoTags"] || []
      repo_tags.each do |tag|
        repo, tag_name = tag.split(":")
        next unless repo == repo_prefix

        result << {
          name: tag_name,
          image: tag,
          size: img.info["Size"],
          created_at: Time.at(img.info["Created"])
        }
      end
    end
  rescue Docker::Error::DockerError => e
    raise Error, "Failed to list snapshots: #{e.message}"
  end

  def destroy_snapshot(user:, name:)
    image_ref = "sc-snap-#{user.name}:#{name}"
    Docker::Image.get(image_ref).remove
  rescue Docker::Error::NotFoundError
    raise Error, "Snapshot '#{name}' not found"
  rescue Docker::Error::DockerError => e
    raise Error, "Failed to destroy snapshot: #{e.message}"
  end

  def restore(sandbox:, snapshot_name:)
    user = sandbox.user
    image_ref = "sc-snap-#{user.name}:#{snapshot_name}"
    was_tailscale = sandbox.tailscale?

    Docker::Image.get(image_ref)

    begin
      TerminalManager.new.close(sandbox: sandbox)
    rescue TerminalManager::Error, Docker::Error::DockerError
      # best-effort terminal cleanup
    end

    if sandbox.tailscale?
      TailscaleManager.new.disconnect_sandbox(sandbox: sandbox)
    end

    if sandbox.container_id.present?
      begin
        old_container = Docker::Container.get(sandbox.container_id)
        old_container.stop(t: 5) rescue nil
        old_container.delete(force: true)
      rescue Docker::Error::NotFoundError
        # Already gone
      end
    end

    container = Docker::Container.create(
      "name" => sandbox.full_name,
      "Image" => image_ref,
      "Hostname" => sandbox.full_name,
      "Env" => [
        "SANDCASTLE_USER=#{user.name}",
        "SANDCASTLE_SSH_KEY=#{user.ssh_public_key}"
      ],
      "HostConfig" => {
        "Runtime" => container_runtime,
        "PortBindings" => {
          "22/tcp" => [ { "HostPort" => sandbox.ssh_port.to_s } ]
        },
        "Binds" => volume_binds(user, sandbox),
        "RestartPolicy" => { "Name" => "unless-stopped" }
      }
    )

    container.start
    sandbox.update!(container_id: container.id, image: image_ref, status: "running")

    if was_tailscale && user.tailscale_enabled?
      TailscaleManager.new.connect_sandbox(sandbox: sandbox)
    end

    sandbox
  rescue Docker::Error::NotFoundError
    raise Error, "Snapshot '#{snapshot_name}' not found"
  rescue Docker::Error::DockerError => e
    raise Error, "Failed to restore snapshot: #{e.message}"
  end

  def connect_info(sandbox:)
    host = ENV.fetch("SANDCASTLE_HOST", "localhost")
    user = sandbox.user.name
    info = {
      host: host,
      port: sandbox.ssh_port,
      user: user,
      command: sandbox.connect_command(host: host)
    }

    if sandbox.tailscale?
      ts_ip = TailscaleManager.new.sandbox_tailscale_ip(sandbox: sandbox)
      if ts_ip.present?
        info[:host] = ts_ip
        info[:port] = 22
        info[:command] = "ssh #{user}@#{ts_ip}"
        info[:tailscale_ip] = ts_ip
      end
    end

    info
  end

  private

  def container_runtime
    @container_runtime ||= begin
      runtimes = Docker.info["Runtimes"] || {}
      if runtimes.key?("sysbox-runc")
        "sysbox-runc"
      else
        Rails.logger.warn("SandboxManager: sysbox-runc not available, falling back to runc (Docker-in-Docker will not work inside sandboxes)")
        "runc"
      end
    end
  end

  def ensure_image(image)
    Docker::Image.create("fromImage" => image)
  rescue Docker::Error::DockerError => e
    raise Error, "Failed to pull image #{image}: #{e.message}"
  end

  def ensure_mount_dirs(user, sandbox)
    if sandbox.mount_home
      FileUtils.mkdir_p("#{DATA_DIR}/users/#{user.name}/home")
    end
    if sandbox.data_path.present?
      dir = "#{DATA_DIR}/users/#{user.name}/data/#{sandbox.data_path}".chomp("/")
      FileUtils.mkdir_p(dir)
    end
  end

  def volume_binds(user, sandbox)
    binds = []
    if sandbox.mount_home
      binds << "#{DATA_DIR}/users/#{user.name}/home:/home/#{user.name}"
    end
    if sandbox.persistent_volume && sandbox.volume_path
      binds << "#{sandbox.volume_path}:/workspace"
    end
    if sandbox.data_path.present?
      host_path = "#{DATA_DIR}/users/#{user.name}/data/#{sandbox.data_path}".chomp("/")
      binds << "#{host_path}:/data"
    end
    binds
  end
end
