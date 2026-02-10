class TailscaleManager
  DATA_DIR = ENV.fetch("SANDCASTLE_DATA_DIR", "/data")
  TAILSCALE_IMAGE = "tailscale/tailscale:latest"

  class Error < StandardError; end

  def enable(user:, auth_key:)
    raise Error, "Tailscale already enabled" if user.tailscale_enabled?

    network_name = "sc-ts-net-#{user.name}"
    container_name = "sc-ts-#{user.name}"
    subnet = subnet_for(user)

    network = create_network(network_name, subnet)
    container = create_sidecar(
      name: container_name,
      user: user,
      network: network_name,
      subnet: subnet,
      auth_key: auth_key
    )

    container.start
    user.update!(
      tailscale_enabled: true,
      tailscale_container_id: container.id,
      tailscale_network: network_name
    )
    user
  rescue Docker::Error::DockerError => e
    # Cleanup on failure
    begin
      Docker::Container.get(container_name).delete(force: true)
    rescue StandardError
      nil
    end
    begin
      Docker::Network.get(network_name).delete
    rescue StandardError
      nil
    end
    raise Error, "Failed to enable Tailscale: #{e.message}"
  end

  def disable(user:)
    raise Error, "Tailscale not enabled" unless user.tailscale_enabled?

    # Disconnect all sandboxes first
    user.sandboxes.active.where(tailscale: true).find_each do |sandbox|
      disconnect_sandbox(sandbox: sandbox)
    end

    # Stop and remove sidecar
    if user.tailscale_container_id.present?
      begin
        container = Docker::Container.get(user.tailscale_container_id)
        container.stop(t: 5) rescue nil
        container.delete(force: true)
      rescue Docker::Error::NotFoundError
        # Already gone
      end
    end

    # Remove network
    if user.tailscale_network.present?
      begin
        Docker::Network.get(user.tailscale_network).delete
      rescue Docker::Error::NotFoundError
        # Already gone
      end
    end

    user.update!(
      tailscale_enabled: false,
      tailscale_container_id: nil,
      tailscale_network: nil
    )
    user
  rescue Docker::Error::DockerError => e
    raise Error, "Failed to disable Tailscale: #{e.message}"
  end

  def status(user:)
    raise Error, "Tailscale not enabled" unless user.tailscale_enabled?
    raise Error, "Sidecar container not found" if user.tailscale_container_id.blank?

    container = Docker::Container.get(user.tailscale_container_id)
    running = container.json.dig("State", "Running")

    result = {
      running: running,
      container_id: user.tailscale_container_id[0..11],
      network: user.tailscale_network,
      connected_sandboxes: user.sandboxes.active.where(tailscale: true).count
    }

    if running
      ip_out = container.exec([ "tailscale", "ip", "--4" ])
      result[:tailscale_ip] = ip_out.first.first&.strip if ip_out.first.any?

      status_out = container.exec([ "tailscale", "status", "--json" ])
      if status_out.first.any?
        begin
          ts_status = JSON.parse(status_out.first.join)
          result[:hostname] = ts_status.dig("Self", "HostName")
          result[:tailnet] = ts_status.dig("MagicDNSSuffix")
          result[:online] = ts_status.dig("Self", "Online")
        rescue JSON::ParserError
          # Status not available yet
        end
      end
    end

    result
  rescue Docker::Error::NotFoundError
    raise Error, "Sidecar container not found — try disabling and re-enabling Tailscale"
  rescue Docker::Error::DockerError => e
    raise Error, "Failed to get Tailscale status: #{e.message}"
  end

  def connect_sandbox(sandbox:)
    user = sandbox.user
    raise Error, "Tailscale not enabled for user" unless user.tailscale_enabled?
    raise Error, "Sandbox not running" unless sandbox.container_id.present?

    network = Docker::Network.get(user.tailscale_network)
    network.connect(sandbox.container_id)
    sandbox.update!(tailscale: true)
    sandbox
  rescue Docker::Error::DockerError => e
    raise Error, "Failed to connect sandbox to Tailscale: #{e.message}"
  end

  def disconnect_sandbox(sandbox:)
    user = sandbox.user
    return sandbox unless sandbox.tailscale? && user.tailscale_network.present?

    if sandbox.container_id.present?
      begin
        network = Docker::Network.get(user.tailscale_network)
        network.disconnect(sandbox.container_id)
      rescue Docker::Error::NotFoundError
        # Network or container already gone
      end
    end

    sandbox.update!(tailscale: false)
    sandbox
  rescue Docker::Error::DockerError => e
    raise Error, "Failed to disconnect sandbox from Tailscale: #{e.message}"
  end

  def sandbox_tailscale_ip(sandbox:)
    user = sandbox.user
    return nil unless sandbox.tailscale? && sandbox.container_id.present? && user.tailscale_network.present?

    container = Docker::Container.get(sandbox.container_id)
    container.json.dig("NetworkSettings", "Networks", user.tailscale_network, "IPAddress")
  rescue Docker::Error::DockerError
    nil
  end

  private

  def subnet_for(user)
    octet = 100 + (user.id % 100)
    "172.#{octet}.0.0/16"
  end

  def create_network(name, subnet)
    Docker::Network.create(
      name,
      "Driver" => "bridge",
      "IPAM" => {
        "Config" => [ { "Subnet" => subnet } ]
      }
    )
  end

  def create_sidecar(name:, user:, network:, subnet:, auth_key:)
    state_dir = "#{DATA_DIR}/users/#{user.name}/tailscale"

    Docker::Container.create(
      "Image" => TAILSCALE_IMAGE,
      "name" => name,
      "Hostname" => "sc-#{user.name}",
      "Env" => [
        "TS_STATE_DIR=/var/lib/tailscale",
        "TS_AUTHKEY=#{auth_key}",
        "TS_HOSTNAME=sc-#{user.name}",
        "TS_EXTRA_ARGS=--advertise-routes=#{subnet} --accept-routes"
      ],
      "HostConfig" => {
        "NetworkMode" => network,
        "CapAdd" => [ "NET_ADMIN", "SYS_MODULE" ],
        "Devices" => [
          { "PathOnHost" => "/dev/net/tun", "PathInContainer" => "/dev/net/tun", "CgroupPermissions" => "rwm" }
        ],
        "Sysctls" => { "net.ipv4.ip_forward" => "1" },
        "Binds" => [ "#{state_dir}:/var/lib/tailscale" ],
        "RestartPolicy" => { "Name" => "unless-stopped" }
      }
    )
  end
end
