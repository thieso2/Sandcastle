class SandboxManager
  DATA_DIR = ENV.fetch("SANDCASTLE_DATA_DIR", "/data")

  class Error < StandardError; end

  def create(user:, name:, image: "sandcastle-sandbox:latest", persistent: false)
    sandbox = user.sandboxes.build(
      name: name,
      image: image,
      status: "pending",
      persistent_volume: persistent
    )

    if persistent
      sandbox.volume_path = "#{DATA_DIR}/sandboxes/#{sandbox.full_name}/vol"
    end

    sandbox.save!

    container = Docker::Container.create(
      "Image" => image,
      "Hostname" => sandbox.full_name,
      "Env" => [
        "SANDCASTLE_USER=#{user.name}",
        "SANDCASTLE_SSH_KEY=#{user.ssh_public_key}"
      ],
      "HostConfig" => {
        "Runtime" => "sysbox-runc",
        "PortBindings" => {
          "22/tcp" => [ { "HostPort" => sandbox.ssh_port.to_s } ]
        },
        "Binds" => volume_binds(user, sandbox),
        "RestartPolicy" => { "Name" => "unless-stopped" }
      }
    )

    container.start
    sandbox.update!(container_id: container.id, status: "running")
    sandbox
  rescue Docker::Error::DockerError => e
    sandbox&.update(status: "destroyed") if sandbox&.persisted?
    raise Error, "Failed to create container: #{e.message}"
  end

  def destroy(sandbox:, keep_volume: false)
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
    sandbox
  rescue Docker::Error::NotFoundError
    sandbox.update!(status: "destroyed", container_id: nil)
    raise Error, "Container not found — sandbox must be recreated"
  end

  def stop(sandbox:)
    return sandbox if sandbox.status == "stopped"

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

  def connect_info(sandbox:)
    host = ENV.fetch("SANDCASTLE_HOST", "localhost")
    {
      host: host,
      port: sandbox.ssh_port,
      user: sandbox.user.name,
      command: sandbox.connect_command(host: host)
    }
  end

  private

  def volume_binds(user, sandbox)
    binds = [
      "#{DATA_DIR}/users/#{user.name}/home:/home/#{user.name}"
    ]
    if sandbox.persistent_volume && sandbox.volume_path
      binds << "#{sandbox.volume_path}:/workspace"
    end
    binds
  end
end
