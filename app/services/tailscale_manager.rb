class TailscaleManager
  DATA_DIR = ENV.fetch("SANDCASTLE_DATA_DIR", "/data")
  TAILSCALE_IMAGE = "tailscale/tailscale:latest"
  TAILSCALE_TAG = ENV.fetch("SANDCASTLE_TAILSCALE_TAG", "").presence
  LOGIN_URL_PATTERN = %r{https://login\.tailscale\.com/\S+}

  class Error < StandardError; end

  # Legacy: one-shot enable with an auth key (still supported for automation)
  def enable(user:, auth_key:)
    raise Error, "Tailscale already active" if user.tailscale_enabled? || user.tailscale_pending?

    network_name, container = create_and_start_sidecar(user: user, auth_key: auth_key)

    user.update!(
      tailscale_state: "enabled",
      tailscale_auto_connect: true,
      tailscale_container_id: container.id,
      tailscale_network: network_name
    )
    user
  rescue Docker::Error::DockerError => e
    cleanup_on_failure(user)
    raise Error, "Failed to enable Tailscale: #{e.message}"
  end

  # Phase 1: create and start sidecar, return immediately
  def start_login(user:)
    raise Error, "Tailscale already active" if user.tailscale_enabled?

    # If pending, clean up the old attempt first
    cleanup_sidecar(user) if user.tailscale_pending?

    network_name, container = create_and_start_sidecar(user: user, auth_key: nil)

    user.update!(
      tailscale_state: "pending",
      tailscale_container_id: container.id,
      tailscale_network: network_name
    )

    { status: "starting" }
  rescue Docker::Error::DockerError => e
    cleanup_on_failure(user)
    raise Error, "Failed to start Tailscale login: #{e.message}"
  end

  # Phase 2: progressive login status check
  # Returns: { status: "starting" | "waiting_for_url" | "login_ready" | "authenticated" | "error" }
  def check_login(user:)
    raise Error, "No pending login" unless user.tailscale_pending?
    raise Error, "Sidecar container not found" if user.tailscale_container_id.blank?

    container = Docker::Container.get(user.tailscale_container_id)
    running = container.json.dig("State", "Running")
    return { status: "starting", message: "Starting sidecar container..." } unless running

    # Kick off `tailscale up` in the background if not already done
    cache_key = "ts_login_started:#{user.id}"
    unless Rails.cache.read(cache_key)
      subnet = subnet_for(user)
      tag = Rails.cache.read("ts_tag:#{user.id}") || TAILSCALE_TAG
      tag_flag = tag ? " --advertise-tags=#{tag}" : ""
      container.exec([
        "sh", "-c",
        "tailscale up --reset" \
        " --advertise-routes=#{subnet}" \
        "#{tag_flag}" \
        " --accept-routes" \
        " --hostname=#{container.json.dig("Config", "Hostname")}" \
        " --timeout=120s &"
      ])
      Rails.cache.write(cache_key, true, expires_in: 5.minutes)
      return { status: "waiting_for_url", message: "Waiting for login URL..." }
    end

    # Check tailscale status for auth progress
    status_out = container.exec([ "tailscale", "status", "--json" ])
    if status_out.first.any?
      ts_status = JSON.parse(status_out.first.join)
      case ts_status["BackendState"]
      when "Running"
        Rails.cache.delete(cache_key)
        user.update!(tailscale_state: "enabled", tailscale_auto_connect: true)
        ip_out = container.exec([ "tailscale", "ip", "--4" ])
        tailscale_ip = ip_out.first.first&.strip if ip_out.first.any?
        return {
          status: "authenticated",
          tailscale_ip: tailscale_ip,
          hostname: ts_status.dig("Self", "HostName"),
          tailnet: ts_status.dig("MagicDNSSuffix")
        }
      when "NeedsLogin"
        auth_url = ts_status["AuthURL"]
        if auth_url.present?
          return { status: "login_ready", login_url: auth_url, message: "Click the link to authenticate" }
        end
      end
    end

    { status: "waiting_for_url", message: "Waiting for login URL..." }
  rescue JSON::ParserError
    { status: "waiting_for_url", message: "Waiting for login URL..." }
  rescue Docker::Error::NotFoundError
    Rails.cache.delete("ts_login_started:#{user.id}")
    user.update!(tailscale_state: "disabled", tailscale_container_id: nil, tailscale_network: nil)
    raise Error, "Sidecar container disappeared"
  rescue Docker::Error::DockerError => e
    raise Error, "Failed to check login: #{e.message}"
  end

  def disable(user:)
    raise Error, "Tailscale not active" if user.tailscale_disabled?

    Rails.cache.delete("ts_login_started:#{user.id}")

    # Disconnect all sandboxes first
    user.sandboxes.active.where(tailscale: true).find_each do |sandbox|
      disconnect_sandbox(sandbox: sandbox)
    end

    cleanup_sidecar(user)

    user.update!(
      tailscale_state: "disabled",
      tailscale_container_id: nil,
      tailscale_network: nil
    )
    user
  rescue Docker::Error::DockerError => e
    raise Error, "Failed to disable Tailscale: #{e.message}"
  end

  def status(user:)
    raise Error, "Tailscale not active" unless user.tailscale_enabled? || user.tailscale_pending?
    raise Error, "Sidecar container not found" if user.tailscale_container_id.blank?

    container = Docker::Container.get(user.tailscale_container_id)
    running = container.json.dig("State", "Running")

    ts_sandboxes = user.sandboxes.active.where(tailscale: true)
    sandbox_ips = ts_sandboxes.map do |sb|
      ip = sandbox_tailscale_ip(sandbox: sb)
      { name: sb.name, ip: ip }
    end

    result = {
      running: running,
      container_id: user.tailscale_container_id[0..11],
      network: user.tailscale_network,
      connected_sandboxes: ts_sandboxes.count,
      sandboxes: sandbox_ips
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
    else
      # Grab last 20 lines of container logs for debugging
      logs = container.logs(stdout: true, stderr: true, tail: 20)
      result[:logs] = logs.encode("UTF-8", invalid: :replace, undef: :replace).strip if logs.present?
      result[:exit_code] = container.json.dig("State", "ExitCode")
      result[:error_reason] = container.json.dig("State", "Error")
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

  def create_and_start_sidecar(user:, auth_key:)
    network_name = "sc-ts-net-#{user.name}"
    container_name = "sc-ts-#{user.name}"
    subnet = subnet_for(user)

    pull_image
    create_network(network_name, subnet)
    remove_existing_container(container_name)
    container = create_sidecar(
      name: container_name,
      user: user,
      network: network_name,
      subnet: subnet,
      auth_key: auth_key
    )
    container.start

    [ network_name, container ]
  end

  def remove_existing_container(name)
    container = Docker::Container.get(name)
    container.stop(t: 5) rescue nil
    container.delete(force: true)
  rescue Docker::Error::NotFoundError
    # No existing container
  end

  def cleanup_sidecar(user)
    if user.tailscale_container_id.present?
      begin
        container = Docker::Container.get(user.tailscale_container_id)
        container.stop(t: 5) rescue nil
        container.delete(force: true)
      rescue Docker::Error::NotFoundError
        # Already gone
      end
    end

    if user.tailscale_network.present?
      begin
        Docker::Network.get(user.tailscale_network).delete
      rescue Docker::Error::NotFoundError
        # Already gone
      end
    end
  end

  def cleanup_on_failure(user)
    container_name = "sc-ts-#{user.name}"
    network_name = "sc-ts-net-#{user.name}"
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
    user.update!(tailscale_state: "disabled", tailscale_container_id: nil, tailscale_network: nil)
  end

  def pull_image
    Docker::Image.get(TAILSCALE_IMAGE)
  rescue Docker::Error::NotFoundError
    Docker::Image.create("fromImage" => TAILSCALE_IMAGE)
  rescue Docker::Error::DockerError
    raise Error, "Failed to pull #{TAILSCALE_IMAGE} — check network connectivity"
  end

  def subnet_for(user)
    base = ENV.fetch("SANDCASTLE_SUBNET", "172.30.99.0/24")
    # Derive per-user /24 by offsetting the third octet from the base
    # e.g. base 172.19.142.0/24, user_id 1 → 172.19.143.0/24
    parts = base.split("/").first.split(".").map(&:to_i)
    offset = 1 + (user.id % 100)
    parts[2] = (parts[2] + offset) % 256
    "#{parts[0]}.#{parts[1]}.#{parts[2]}.0/24"
  end

  def create_network(name, subnet)
    Docker::Network.get(name)
  rescue Docker::Error::NotFoundError
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

    config = {
      "Image" => TAILSCALE_IMAGE,
      "name" => name,
      "Hostname" => "sc-#{user.name}",
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
    }

    if auth_key.present?
      # Use containerboot (default entrypoint) with auth key for automated flow
      config["Env"] = [
        "TS_STATE_DIR=/var/lib/tailscale",
        "TS_HOSTNAME=sc-#{user.name}",
        "TS_EXTRA_ARGS=--advertise-routes=#{subnet} --accept-routes#{TAILSCALE_TAG ? " --advertise-tags=#{TAILSCALE_TAG}" : ""}",
        "TS_AUTH_ONCE=true",
        "TS_AUTHKEY=#{auth_key}"
      ]
    else
      # Run tailscaled directly — we manage login via `tailscale up`
      config["Entrypoint"] = [ "tailscaled", "--state=/var/lib/tailscale/tailscaled.state" ]
      config["Cmd"] = []
    end

    Docker::Container.create(config)
  end
end
