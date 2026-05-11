require "shellwords"

class TailscaleManager
  DATA_DIR = ENV.fetch("SANDCASTLE_DATA_DIR", "/data")
  TAILSCALE_IMAGE = "tailscale/tailscale:latest"
  TAILSCALE_TAG = ENV.fetch("SANDCASTLE_TAILSCALE_TAG", "").presence
  LOGIN_URL_PATTERN = %r{https://login\.tailscale\.com/\S+}

  # Stable Tailscale machine name for this server's sidecar containers.
  # Derived from SANDCASTLE_NAME (set in .env) or falls back to the system hostname.
  # Slugified: lowercase, non-alphanumeric runs → "-", leading/trailing "-" stripped.
  TAILSCALE_HOSTNAME = begin
    name = ENV.fetch("SANDCASTLE_NAME", "").presence || Socket.gethostname
    "sc-" + name.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
  end

  class Error < StandardError; end

  # Restore sidecar from persisted tailscaled.state without re-authentication.
  # Used after reinstall or crash when interactive-login state survives on disk.
  # Note: we intentionally skip checking File.exist? for the state file because
  # the tailscale directory is root-owned (drwx------) and unreadable by the
  # sandcastle process. Containerboot will handle missing state gracefully.
  def restore_from_state(user:)
    raise Error, "Tailscale already active" if user.tailscale_enabled? || user.tailscale_pending?

    network_name = "sc-ts-net-#{user.name}"
    container_name = "sc-ts-#{user.name}"
    subnet = subnet_for(user)

    pull_image
    create_network(network_name, subnet)
    remove_existing_container(container_name)
    # Intentionally skip clear_tailscale_state — we rely on existing saved credentials
    # Use raw tailscaled (same as interactive flow) — NOT containerboot.
    # Containerboot runs `tailscale logout` on SIGTERM, which would expire the
    # saved node key. Raw tailscaled exits cleanly without touching auth state.
    container = create_sidecar(
      name: container_name,
      user: user,
      network: network_name,
      subnet: subnet,
      auth_key: nil
    )
    container.start

    # Re-advertise routes after tailscaled reconnects — the subnet may have changed
    # after a reinstall (Docker reallocates from the pool). No --reset so we preserve
    # credentials and other settings in the persisted state. Also re-applies the
    # canonical hostname so it reflects the current SANDCASTLE_NAME.
    tag_flag = TAILSCALE_TAG ? " --advertise-tags=#{TAILSCALE_TAG}" : ""
    container.exec([
      "sh", "-c",
      "sleep 3 && tailscale up" \
      " --advertise-routes=#{subnet}" \
      " --accept-routes" \
      "#{tag_flag}" \
      " --hostname=#{TAILSCALE_HOSTNAME}" \
      " --timeout=60s &"
    ])

    user.update!(
      tailscale_state: "enabled",
      tailscale_auto_connect: true,
      tailscale_container_id: container.id,
      tailscale_network: network_name,
      tailscale_subnet: subnet
    )
    ensure_dns_resolver(user)
    user
  rescue Docker::Error::DockerError => e
    cleanup_on_failure(user)
    raise Error, "Failed to restore Tailscale from state: #{e.message}"
  end

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
    save_auth_key(user, auth_key)
    ensure_dns_resolver(user)
    user
  rescue Docker::Error::DockerError => e
    cleanup_on_failure(user)
    raise Error, "Failed to enable Tailscale: #{e.message}"
  end

  # Phase 1: create and start sidecar, return immediately.
  # Called from TailscaleLoginJob — user is already in "pending" state.
  def start_login(user:)
    raise Error, "Tailscale already active" if user.tailscale_enabled?

    # If there's an old container, clean up first
    cleanup_sidecar(user) if user.tailscale_container_id.present?

    hostname = Rails.cache.read("ts_hostname:#{user.id}")
    network_name, container = create_and_start_sidecar(user: user, auth_key: nil, hostname: hostname)

    user.update!(
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
        ensure_dns_resolver(user)
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

    cleanup_dns_resolver(user)
    cleanup_sidecar(user)

    user.update!(
      tailscale_state: "disabled",
      tailscale_container_id: nil,
      tailscale_network: nil
    )
    delete_auth_key(user)
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
          tags = ts_status.dig("Self", "Tags")
          result[:tags] = tags if tags.present?
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

    # Verify container exists and check if already connected
    container = Docker::Container.get(sandbox.container_id)
    connected_networks = container.info.dig("NetworkSettings", "Networks") || {}
    if connected_networks.key?(user.tailscale_network)
      write_sandbox_runtime_metadata(container: container, sandbox: sandbox)
      return sandbox
    end

    network = Docker::Network.get(user.tailscale_network)

    # Sysbox containers have heavier init (user namespace, rootless daemon) so
    # the network namespace may not be attachable immediately after start.
    retries = 0
    begin
      network.connect(sandbox.container_id)
    rescue Docker::Error::ServerError => e
      raise unless e.message.include?("network sandbox") && retries < 3
      retries += 1
      sleep retries
      retry
    end

    sandbox.update!(tailscale: true)
    container.refresh!
    write_sandbox_runtime_metadata(container: container, sandbox: sandbox)
    ensure_dns_resolver(user)
    sandbox
  rescue Error
    raise
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
      rescue Docker::Error::NotFoundError, Docker::Error::DockerError
        # Network/container already gone or container not connected — desired state reached
      end
    end

    sandbox.update!(tailscale: false)
    publish_dns(user) if user.tailscale_enabled?
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

  def write_sandbox_runtime_metadata(container:, sandbox:)
    tailscale_ip = container.json.dig("NetworkSettings", "Networks", sandbox.user.tailscale_network, "IPAddress").presence || "none"
    dns_name = DnsManager.new.hostname_for(sandbox).presence || "none"
    project_name = sandbox.project_name.presence || "none"
    project_path = sandbox.project_path.presence || "none"
    content = {
      "SC_TAILSCALE" => sandbox.tailscale? ? "enabled" : "disabled",
      "SC_TAILSCALE_IP" => tailscale_ip,
      "SC_DNS" => dns_name,
      "SC_PROJECT" => project_name,
      "SC_PROJECT_PATH" => project_path
    }.map { |key, value| "#{key}=#{Shellwords.shellescape(value)}" }.join("\n") + "\n"

    container.exec([
      "sh", "-c",
      <<~'SH',
        install -d -m 0755 /etc/sandcastle
        printf '%s' "$1" > /etc/sandcastle/runtime
        chmod 0644 /etc/sandcastle/runtime

        if [ -f /etc/sandcastle/settings ]; then
          tmp="$(mktemp)"
          sed '/^project:/d;/^project path:/d;/^tailscale:/d;/^tailscale ip:/d;/^dns:/d' /etc/sandcastle/settings > "$tmp"
          {
            cat "$tmp"
            . /etc/sandcastle/runtime
            tailscale_display="${SC_TAILSCALE:-disabled}"
            if [ "$tailscale_display" = "enabled" ] && [ "${SC_TAILSCALE_IP:-none}" != "none" ]; then
              tailscale_display="enabled (${SC_TAILSCALE_IP})"
            fi
            printf 'project: %s\n' "${SC_PROJECT:-none}"
            printf 'project path: %s\n' "${SC_PROJECT_PATH:-none}"
            printf 'tailscale: %s\n' "$tailscale_display"
            printf 'tailscale ip: %s\n' "${SC_TAILSCALE_IP:-none}"
            printf 'dns: %s\n' "${SC_DNS:-none}"
          } > /etc/sandcastle/settings
          rm -f "$tmp"
          chmod 0644 /etc/sandcastle/settings
        fi
      SH
      "_", content
    ])
  rescue Docker::Error::DockerError => e
    Rails.logger.warn("Failed to write Sandcastle runtime metadata for #{sandbox.full_name}: #{e.message}")
  end

  def auth_key_path(user)
    File.join(DATA_DIR, "users", user.name, "tailscale", ".auth_key")
  end

  private

  def save_auth_key(user, auth_key)
    path = auth_key_path(user)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, auth_key)
    File.chmod(0o600, path)
  end

  def ensure_dns_resolver(user)
    DnsManager.new.ensure_resolver(user: user)
  rescue => e
    Rails.logger.warn("TailscaleManager: DNS resolver setup for #{user.name} failed: #{e.message}")
  end

  def publish_dns(user)
    DnsManager.new.publish(user: user)
  rescue => e
    Rails.logger.warn("TailscaleManager: DNS publish for #{user.name} failed: #{e.message}")
  end

  def cleanup_dns_resolver(user)
    DnsManager.new.cleanup(user)
  rescue => e
    Rails.logger.warn("TailscaleManager: DNS cleanup for #{user.name} failed: #{e.message}")
  end

  def delete_auth_key(user)
    path = auth_key_path(user)
    File.delete(path) if File.exist?(path)
  rescue Errno::ENOENT
    # already gone
  end

  def create_and_start_sidecar(user:, auth_key:, hostname: nil)
    network_name = "sc-ts-net-#{user.name}"
    container_name = "sc-ts-#{user.name}"
    subnet = subnet_for(user)

    pull_image
    create_network(network_name, subnet)
    remove_existing_container(container_name)
    clear_tailscale_state(user)
    container = create_sidecar(
      name: container_name,
      user: user,
      network: network_name,
      subnet: subnet,
      auth_key: auth_key,
      hostname: hostname
    )
    container.start

    # Persist the subnet so it survives reinstalls (subnet_for reads this first).
    user.update_column(:tailscale_subnet, subnet)

    [ network_name, container ]
  end

  def remove_existing_container(name)
    container = Docker::Container.get(name)
    container.stop(t: 5) rescue nil
    container.delete(force: true)
  rescue Docker::Error::NotFoundError
    # No existing container
  end

  # Remove stale tailscaled.state so the daemon starts fresh.
  # Stale state causes tailscaled to immediately set up VPN routes before
  # authentication, which silently drops all normal internet traffic.
  def clear_tailscale_state(user)
    state_file = "#{DATA_DIR}/users/#{user.name}/tailscale/tailscaled.state"
    File.delete(state_file) if File.exist?(state_file)
  rescue Errno::ENOENT
    # already gone
  end

  def cleanup_sidecar(user)
    # Try by stored container ID first, then by name as fallback
    container_name = "sc-ts-#{user.name}"
    [ user.tailscale_container_id, container_name ].compact.uniq.each do |ref|
      begin
        container = Docker::Container.get(ref)
        container.stop(t: 5) rescue nil
        container.delete(force: true)
      rescue Docker::Error::NotFoundError
        # Already gone
      end
    end

    # Clean up network by stored name, then by convention
    network_name = "sc-ts-net-#{user.name}"
    [ user.tailscale_network, network_name ].compact.uniq.each do |ref|
      begin
        Docker::Network.get(ref).delete
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
    pool = ENV["DOCKYARD_POOL_BASE"]

    # 1. Use the subnet stored in the DB — but only if it still falls inside the
    # current pool. If DOCKYARD_POOL_BASE changed (or was previously wrong), the
    # stored subnet would be outside the host MASQUERADE rule and the sidecar
    # would have no internet. Drop it and regenerate.
    if user.tailscale_subnet.present?
      if pool.blank? || subnet_in_pool?(user.tailscale_subnet, pool)
        return user.tailscale_subnet
      end
      Rails.logger.warn(
        "TailscaleManager: stored subnet #{user.tailscale_subnet} for #{user.name} " \
        "is outside DOCKYARD_POOL_BASE #{pool} — regenerating"
      )
      user.update_column(:tailscale_subnet, nil)
    end

    # 2. If the network already exists on Docker, read its actual subnet
    # (same validation as above).
    begin
      network = Docker::Network.get("sc-ts-net-#{user.name}")
      ipam = network.info.dig("IPAM", "Config")
      existing = ipam&.first&.dig("Subnet")
      if existing.present?
        return existing if pool.blank? || subnet_in_pool?(existing, pool)
        Rails.logger.warn(
          "TailscaleManager: existing network sc-ts-net-#{user.name} subnet " \
          "#{existing} is outside DOCKYARD_POOL_BASE #{pool} — caller must remove it"
        )
      end
    rescue Docker::Error::NotFoundError
      # Network doesn't exist yet — fall through to generate a random /24
    end

    # 3. Generate a random /24 from the pool (first allocation)
    if pool
      parts = pool.split("/").first.split(".").map(&:to_i)
    else
      parts = [ 10, rand(1..254), 0, 0 ]
    end
    parts[2] = rand(1..254)
    "#{parts[0]}.#{parts[1]}.#{parts[2]}.0/24"
  end

  # Returns true if `subnet` (e.g. "10.89.42.0/24") is fully contained in `pool`
  # (e.g. "10.89.0.0/16"). Used to catch DOCKYARD_POOL_BASE drift before it
  # causes silent loss of internet for Tailscale sidecars.
  def subnet_in_pool?(subnet, pool)
    require "ipaddr"
    IPAddr.new(pool).include?(IPAddr.new(subnet))
  rescue IPAddr::Error
    false
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

  def create_sidecar(name:, user:, network:, subnet:, auth_key:, hostname: nil)
    state_dir = "#{DATA_DIR}/users/#{user.name}/tailscale"
    ts_hostname = hostname.presence || TAILSCALE_HOSTNAME

    # Dev fallback: when the host can't expose /dev/net/tun (e.g. Sysbox),
    # fall back to Tailscale's userspace networking. Subnet routing is then
    # limited, but login and tailnet reachability still work — enough to
    # exercise the app's Tailscale flow end-to-end in development.
    userspace = ActiveModel::Type::Boolean.new.cast(ENV["SANDCASTLE_TAILSCALE_USERSPACE"])

    host_config = {
      "NetworkMode" => network,
      # Dockyard defaults to sysbox-runc so sandboxes can run Docker-in-Docker,
      # but Tailscale subnet routing needs kernel netfilter/SNAT support that
      # Sysbox does not expose inside the sidecar network namespace.
      "Runtime" => "runc",
      "Sysctls" => { "net.ipv4.ip_forward" => "1" },
      "Binds" => [ "#{state_dir}:/var/lib/tailscale" ],
      "RestartPolicy" => { "Name" => "unless-stopped" }
    }

    unless userspace
      host_config["Binds"] << "/lib/modules:/lib/modules:ro"
      host_config["CapAdd"] = [ "NET_ADMIN", "SYS_MODULE" ]
      host_config["Devices"] = [
        { "PathOnHost" => "/dev/net/tun", "PathInContainer" => "/dev/net/tun", "CgroupPermissions" => "rwm" }
      ]
    end

    config = {
      "Image" => TAILSCALE_IMAGE,
      "name" => name,
      "Hostname" => ts_hostname,
      "HostConfig" => host_config
    }

    if auth_key.present?
      # Use containerboot (default entrypoint) with auth key for automated flow
      env = [
        "TS_STATE_DIR=/var/lib/tailscale",
        "TS_HOSTNAME=#{ts_hostname}",
        "TS_EXTRA_ARGS=--advertise-routes=#{subnet} --accept-routes#{TAILSCALE_TAG ? " --advertise-tags=#{TAILSCALE_TAG}" : ""}",
        "TS_AUTH_ONCE=true",
        "TS_AUTHKEY=#{auth_key}"
      ]
      env << "TS_USERSPACE=true" << "TS_TUN=userspace-networking" if userspace
      config["Env"] = env
    else
      # Run tailscaled directly — we manage login via `tailscale up`.
      # Also used for restore_from_state: raw tailscaled exits without running
      # `tailscale logout` on SIGTERM, preserving saved credentials in state file.
      # Fix ownership first: Tailscale image updates may change which user the daemon
      # runs as (e.g. root vs nobody), leaving persisted state files unreadable.
      # With userns-remap the UID mismatch causes "permission denied" on startup.
      tun_flag = userspace ? " --tun=userspace-networking" : ""
      config["Entrypoint"] = [ "sh", "-c", "chown -R root:root /var/lib/tailscale 2>/dev/null; exec tailscaled --state=/var/lib/tailscale/tailscaled.state#{tun_flag}" ]
      config["Cmd"] = []
    end

    Docker::Container.create(config)
  end
end
