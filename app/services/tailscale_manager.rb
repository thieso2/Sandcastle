class TailscaleManager
  DATA_DIR = ENV.fetch("SANDCASTLE_DATA_DIR", "/data")
  TAILSCALE_IMAGE = "sandcastle-tailscale"
  LOGIN_URL_PATTERN = %r{https://login\.tailscale\.com/\S+}

  class Error < StandardError; end

  # Legacy: one-shot enable with an auth key (still supported for automation)
  def enable(user:, auth_key:)
    raise Error, "Tailscale already active" if user.tailscale_enabled? || user.tailscale_pending?

    network_name, instance_name = create_and_start_sidecar(user: user, auth_key: auth_key)

    user.update!(
      tailscale_state: "enabled",
      tailscale_container_id: instance_name,
      tailscale_network: network_name
    )
    user
  rescue IncusClient::Error => e
    cleanup_on_failure(user)
    raise Error, "Failed to enable Tailscale: #{e.message}"
  end

  # Phase 1: start sidecar without auth key, return login URL
  def start_login(user:)
    raise Error, "Tailscale already active" if user.tailscale_enabled?

    # If pending, clean up the old attempt first
    cleanup_sidecar(user) if user.tailscale_pending?

    subnet = subnet_for(user)
    network_name, instance_name = create_and_start_sidecar(user: user, auth_key: nil)

    user.update!(
      tailscale_state: "pending",
      tailscale_container_id: instance_name,
      tailscale_network: network_name
    )

    # Wait for tailscaled to be ready
    sleep 3

    login_url = fetch_login_url(instance_name, subnet, user)
    unless login_url
      sleep 3
      login_url = fetch_login_url(instance_name, subnet, user)
    end
    raise Error, "Could not get login URL — tailscaled may not be ready yet" unless login_url

    { login_url: login_url }
  rescue IncusClient::Error => e
    cleanup_on_failure(user)
    raise Error, "Failed to start Tailscale login: #{e.message}"
  end

  # Phase 2: check if the user has completed browser auth
  def check_login(user:)
    raise Error, "No pending login" unless user.tailscale_pending?
    raise Error, "Sidecar instance not found" if user.tailscale_container_id.blank?

    state = incus.get_instance_state(user.tailscale_container_id)
    return { status: "pending" } unless state["status"] == "Running"

    result = incus.exec(user.tailscale_container_id, command: [ "tailscale", "status", "--json" ])
    if result[:stdout].present?
      ts_status = JSON.parse(result[:stdout])
      if ts_status.dig("BackendState") == "Running"
        user.update!(tailscale_state: "enabled")
        ip_result = incus.exec(user.tailscale_container_id, command: [ "tailscale", "ip", "--4" ])
        tailscale_ip = ip_result[:stdout]&.strip
        return {
          status: "authenticated",
          tailscale_ip: tailscale_ip.presence,
          hostname: ts_status.dig("Self", "HostName"),
          tailnet: ts_status.dig("MagicDNSSuffix")
        }
      end
    end

    { status: "pending" }
  rescue JSON::ParserError
    { status: "pending" }
  rescue IncusClient::NotFoundError
    user.update!(tailscale_state: "disabled", tailscale_container_id: nil, tailscale_network: nil)
    raise Error, "Sidecar instance disappeared"
  rescue IncusClient::Error => e
    raise Error, "Failed to check login: #{e.message}"
  end

  def disable(user:)
    raise Error, "Tailscale not active" if user.tailscale_disabled?

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
  rescue IncusClient::Error => e
    raise Error, "Failed to disable Tailscale: #{e.message}"
  end

  def status(user:)
    raise Error, "Tailscale not active" unless user.tailscale_enabled? || user.tailscale_pending?
    raise Error, "Sidecar instance not found" if user.tailscale_container_id.blank?

    state = incus.get_instance_state(user.tailscale_container_id)
    running = state["status"] == "Running"

    ts_sandboxes = user.sandboxes.active.where(tailscale: true)
    sandbox_ips = ts_sandboxes.map do |sb|
      ip = sandbox_tailscale_ip(sandbox: sb)
      { name: sb.name, ip: ip }
    end

    result = {
      running: running,
      container_id: user.tailscale_container_id,
      network: user.tailscale_network,
      connected_sandboxes: ts_sandboxes.count,
      sandboxes: sandbox_ips
    }

    if running
      ip_result = incus.exec(user.tailscale_container_id, command: [ "tailscale", "ip", "--4" ])
      result[:tailscale_ip] = ip_result[:stdout]&.strip if ip_result[:stdout].present?

      status_result = incus.exec(user.tailscale_container_id, command: [ "tailscale", "status", "--json" ])
      if status_result[:stdout].present?
        begin
          ts_status = JSON.parse(status_result[:stdout])
          result[:hostname] = ts_status.dig("Self", "HostName")
          result[:tailnet] = ts_status.dig("MagicDNSSuffix")
          result[:online] = ts_status.dig("Self", "Online")
        rescue JSON::ParserError
          # Status not available yet
        end
      end
    end

    result
  rescue IncusClient::NotFoundError
    raise Error, "Sidecar instance not found — try disabling and re-enabling Tailscale"
  rescue IncusClient::Error => e
    raise Error, "Failed to get Tailscale status: #{e.message}"
  end

  def connect_sandbox(sandbox:)
    user = sandbox.user
    raise Error, "Tailscale not enabled for user" unless user.tailscale_enabled?
    raise Error, "Sandbox not running" unless sandbox.container_id.present?

    incus.add_device(sandbox.container_id, "ts-nic", {
      "type" => "nic",
      "network" => user.tailscale_network
    })
    sandbox.update!(tailscale: true)
    sandbox
  rescue IncusClient::Error => e
    raise Error, "Failed to connect sandbox to Tailscale: #{e.message}"
  end

  def disconnect_sandbox(sandbox:)
    user = sandbox.user
    return sandbox unless sandbox.tailscale? && user.tailscale_network.present?

    if sandbox.container_id.present?
      begin
        incus.remove_device(sandbox.container_id, "ts-nic")
      rescue IncusClient::NotFoundError
        # Instance or device already gone
      end
    end

    sandbox.update!(tailscale: false)
    sandbox
  rescue IncusClient::Error => e
    raise Error, "Failed to disconnect sandbox from Tailscale: #{e.message}"
  end

  def sandbox_tailscale_ip(sandbox:)
    user = sandbox.user
    return nil unless sandbox.tailscale? && sandbox.container_id.present? && user.tailscale_network.present?

    state = incus.get_instance_state(sandbox.container_id)
    # Look for the IP on the Tailscale network NIC (eth1 or the ts-nic device)
    networks = state["network"] || {}
    networks.each do |_iface, net_info|
      addresses = net_info["addresses"] || []
      addresses.each do |addr|
        # Find non-link-local IPv4 address on the Tailscale bridge
        next unless addr["family"] == "inet"
        next if addr["address"].start_with?("127.")
        ip = addr["address"]
        # Match the user's Tailscale subnet
        subnet_prefix = "172.#{100 + (user.id % 100)}."
        return ip if ip.start_with?(subnet_prefix)
      end
    end
    nil
  rescue IncusClient::Error
    nil
  end

  private

  def incus
    @incus ||= IncusClient.new
  end

  def create_and_start_sidecar(user:, auth_key:)
    network_name = "sc-ts-net-#{user.name}"
    instance_name = "sc-ts-#{user.name}"
    subnet = subnet_for(user)

    create_ts_network(network_name, subnet)
    create_sidecar(
      name: instance_name,
      user: user,
      network: network_name,
      subnet: subnet,
      auth_key: auth_key
    )
    incus.change_state(instance_name, action: "start")

    [ network_name, instance_name ]
  end

  def fetch_login_url(instance_name, subnet, user)
    result = incus.exec(instance_name, command: [
      "tailscale", "up",
      "--reset",
      "--advertise-routes=#{subnet}",
      "--accept-routes",
      "--hostname=sc-#{user.name}",
      "--timeout=10s"
    ])
    combined = "#{result[:stdout]}\n#{result[:stderr]}"
    match = combined.match(LOGIN_URL_PATTERN)
    match[0] if match
  rescue IncusClient::Error
    nil
  end

  def cleanup_sidecar(user)
    if user.tailscale_container_id.present?
      begin
        incus.change_state(user.tailscale_container_id, action: "stop", force: true)
      rescue IncusClient::NotFoundError, IncusClient::Error
        # Already gone or stopped
      end

      begin
        incus.delete_instance(user.tailscale_container_id)
      rescue IncusClient::NotFoundError
        # Already gone
      end
    end

    if user.tailscale_network.present?
      begin
        incus.delete_network(user.tailscale_network)
      rescue IncusClient::NotFoundError
        # Already gone
      end
    end
  end

  def cleanup_on_failure(user)
    instance_name = "sc-ts-#{user.name}"
    network_name = "sc-ts-net-#{user.name}"
    begin
      incus.change_state(instance_name, action: "stop", force: true)
    rescue StandardError
      nil
    end
    begin
      incus.delete_instance(instance_name)
    rescue StandardError
      nil
    end
    begin
      incus.delete_network(network_name)
    rescue StandardError
      nil
    end
    user.update!(tailscale_state: "disabled", tailscale_container_id: nil, tailscale_network: nil)
  end

  def subnet_for(user)
    octet = 100 + (user.id % 100)
    "172.#{octet}.0.0/16"
  end

  def create_ts_network(name, subnet)
    ip_with_mask = subnet.sub(".0/16", ".1/16")
    incus.create_network(name, config: {
      "ipv4.address" => ip_with_mask,
      "ipv4.nat" => "true",
      "ipv6.address" => "none"
    })
  rescue IncusClient::Error => e
    # Network may already exist from a previous attempt
    raise unless e.message.include?("already exists")
  end

  def create_sidecar(name:, user:, network:, subnet:, auth_key:)
    state_dir = "#{DATA_DIR}/users/#{user.name}/tailscale"

    cloud_init = if auth_key.present?
      <<~CLOUD_INIT
        #cloud-config
        runcmd:
          - tailscale up --authkey=#{auth_key} --advertise-routes=#{subnet} --accept-routes --hostname=sc-#{user.name}
      CLOUD_INIT
    else
      <<~CLOUD_INIT
        #cloud-config
        runcmd:
          - systemctl start tailscaled
      CLOUD_INIT
    end

    devices = {
      "ts-net" => {
        "type" => "nic",
        "network" => network
      },
      "ts-state" => {
        "type" => "disk",
        "source" => state_dir,
        "path" => "/var/lib/tailscale"
      }
    }

    incus.create_instance(
      name: name,
      source: { type: "image", alias: TAILSCALE_IMAGE },
      config: {
        "user.user-data" => cloud_init,
        "security.nesting" => "true"
      },
      devices: devices,
      profiles: [ "default" ]
    )
  end
end
