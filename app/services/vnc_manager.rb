class VncManager
  DATA_DIR = ENV.fetch("SANDCASTLE_DATA_DIR", "/data")
  NOVNC_IMAGE = ENV.fetch("SANDCASTLE_NOVNC_IMAGE", "gotget/novnc:latest")
  NETWORK_NAME = "sandcastle-web"
  DYNAMIC_DIR = File.join(DATA_DIR, "traefik", "dynamic")

  class Error < StandardError; end

  # Opens a web-based VNC session for the given sandbox.
  # Returns the URL path to the noVNC session.
  def open(sandbox:)
    raise Error, "Sandbox is not running" unless sandbox.status == "running"
    raise Error, "Sandbox has no container" if sandbox.container_id.blank?

    user = sandbox.user
    container_name = vnc_container_name(sandbox)

    # Idempotent: if noVNC container already running, return URL
    if container_running?(container_name)
      return vnc_url(sandbox)
    end

    pull_image
    ensure_network
    connect_sandbox_to_network(sandbox)

    # Write Traefik config early so it has time to detect the new route
    write_traefik_config(sandbox)

    create_novnc_container(sandbox: sandbox, user: user)

    # Give Traefik time to detect the new route configuration
    sleep 2

    vnc_url(sandbox)
  rescue Docker::Error::DockerError => e
    raise Error, "Failed to open browser: #{e.message}"
  rescue SystemCallError => e
    raise Error, "Failed to open browser: #{e.message}"
  end

  # Closes the web VNC session for the given sandbox.
  def close(sandbox:)
    container_name = vnc_container_name(sandbox)

    # Stop and remove noVNC container
    begin
      container = Docker::Container.get(container_name)
      container.stop(t: 3) rescue nil
      container.delete(force: true)
    rescue Docker::Error::NotFoundError
      # Already gone
    end

    # Delete Traefik config
    delete_traefik_config(sandbox)
  rescue Docker::Error::DockerError => e
    Rails.logger.error("VncManager: close failed for #{sandbox.full_name}: #{e.message}")
  end

  # Returns true if the noVNC container is running for this sandbox.
  def active?(sandbox:)
    container_running?(vnc_container_name(sandbox))
  end

  # Removes orphaned noVNC containers whose sandbox no longer exists or is not running.
  def cleanup_orphaned
    Docker::Container.all(all: true).each do |container|
      name = container.info.dig("Names")&.first&.delete_prefix("/")
      next unless name&.start_with?("sc-vnc-")

      labels = container.info["Labels"] || {}
      sandbox_id = labels["sandcastle.sandbox_id"]&.to_i

      sandbox = sandbox_id ? Sandbox.find_by(id: sandbox_id) : nil
      should_remove = sandbox.nil? || sandbox.status != "running"

      if should_remove
        container.stop(t: 3) rescue nil
        container.delete(force: true)
        Rails.logger.info("VncManager: removed orphaned noVNC container #{name}")

        # Clean up Traefik config if we have a sandbox_id
        if sandbox_id
          config_path = File.join(DYNAMIC_DIR, "vnc-#{sandbox_id}.yml")
          File.delete(config_path) if File.exist?(config_path)
        end
      end
    end
  rescue Docker::Error::DockerError => e
    Rails.logger.error("VncManager: orphan cleanup failed: #{e.message}")
  end

  private

  def vnc_container_name(sandbox)
    "sc-vnc-#{sandbox.full_name}"
  end

  def vnc_url(sandbox)
    id = sandbox.id
    # noVNC builds the WebSocket URL as wss://host/<path setting>.
    # Default path is "websockify". Without ?path=..., noVNC would try
    # wss://host/websockify which Traefik has no route for.
    # Pass the full routed path so Traefik's stripPrefix reduces it to
    # /websockify before websockify receives the connection.
    "/vnc/#{id}/novnc/vnc.html?path=vnc/#{id}/novnc/websockify"
  end

  def container_running?(name)
    container = Docker::Container.get(name)
    container.json.dig("State", "Running") == true
  rescue Docker::Error::NotFoundError
    false
  end

  def pull_image
    Docker::Image.get(NOVNC_IMAGE)
  rescue Docker::Error::NotFoundError
    Docker::Image.create("fromImage" => NOVNC_IMAGE)
  rescue Docker::Error::DockerError
    raise Error, "Failed to pull #{NOVNC_IMAGE} — check network connectivity"
  end

  def ensure_network
    Docker::Network.get(NETWORK_NAME)
  rescue Docker::Error::NotFoundError
    Docker::Network.create(NETWORK_NAME, "Driver" => "bridge")
  end

  def connect_sandbox_to_network(sandbox)
    return unless sandbox.container_id.present?

    network = Docker::Network.get(NETWORK_NAME)
    container = Docker::Container.get(sandbox.container_id)

    networks = container.json.dig("NetworkSettings", "Networks") || {}
    return if networks.key?(NETWORK_NAME)

    network.connect(sandbox.container_id)
  rescue Docker::Error::NotFoundError
    # Container no longer exists - sync job will fix the DB state
    raise Error, "Sandbox container not found. Please refresh and try again."
  end

  def create_novnc_container(sandbox:, user:)
    container_name = vnc_container_name(sandbox)

    # Remove any existing container with this name
    begin
      old = Docker::Container.get(container_name)
      old.stop(t: 3) rescue nil
      old.delete(force: true)
    rescue Docker::Error::NotFoundError
      # No existing container
    end

    host_config = {
      "NetworkMode" => NETWORK_NAME,
      "RestartPolicy" => { "Name" => "no" },
      "Memory" => 64 * 1024 * 1024, # 64MB — just serving static HTML
      "NanoCpus" => 100_000_000 # 0.1 CPU
    }

    # Run the noVNC image as a plain HTTP file server for noVNC static assets.
    # WebSocket VNC connections are routed by Traefik directly to x11vnc's
    # native WebSocket port (5901) in the sandbox — no websockify needed.
    container = Docker::Container.create(
      "name" => container_name,
      "Image" => NOVNC_IMAGE,
      "Entrypoint" => [ "python3", "-m", "http.server", "--directory", "/usr/src/app/noVNC", "6080" ],
      "HostConfig" => host_config,
      "Labels" => {
        "sandcastle.sandbox_id" => sandbox.id.to_s,
        "sandcastle.role" => "novnc"
      }
    )

    container.start
    container
  end

  def write_traefik_config(sandbox)
    FileUtils.mkdir_p(DYNAMIC_DIR)

    host = ENV.fetch("SANDCASTLE_HOST", "localhost")
    id = sandbox.id
    container_name = vnc_container_name(sandbox)
    sandbox_name   = sandbox.full_name

    base_rule = if ENV["SANDCASTLE_TLS_MODE"] == "selfsigned"
      "HostRegexp(`.+`) && PathPrefix(`/vnc/#{id}/novnc`)"
    else
      "Host(`#{host}`) && PathPrefix(`/vnc/#{id}/novnc`)"
    end

    # Two routers on the same path prefix:
    # - HTTP router  → noVNC static files container (port 6080)
    # - WebSocket router → x11vnc native WebSocket in the sandbox (port 5901)
    # Splitting avoids routing WebSocket traffic through the old gotget/novnc
    # websockify, which sends raw WS frames that x11vnc 0.9.17 misidentifies.
    config = {
      "http" => {
        "routers" => {
          "vnc-html-#{id}" => {
            "rule" => "#{base_rule} && !HeaderRegexp(`Upgrade`, `websocket`)",
            "service" => "vnc-html-#{id}",
            "entryPoints" => [ "websecure" ],
            "tls" => tls_config,
            "middlewares" => [ "vnc-auth-#{id}", "vnc-stripprefix-#{id}" ],
            "priority" => 101
          },
          "vnc-ws-#{id}" => {
            "rule" => "#{base_rule} && HeaderRegexp(`Upgrade`, `websocket`)",
            "service" => "vnc-ws-#{id}",
            "entryPoints" => [ "websecure" ],
            "tls" => tls_config,
            "middlewares" => [ "vnc-auth-#{id}", "vnc-stripprefix-#{id}" ],
            "priority" => 101
          }
        },
        "middlewares" => {
          "vnc-auth-#{id}" => {
            "forwardAuth" => {
              "address" => "http://sandcastle-web:80/vnc/auth",
              "trustForwardHeader" => true
            }
          },
          "vnc-stripprefix-#{id}" => {
            "stripPrefix" => {
              "prefixes" => [ "/vnc/#{id}/novnc" ]
            }
          }
        },
        "services" => {
          # noVNC HTML/JS/CSS static files
          "vnc-html-#{id}" => {
            "loadBalancer" => {
              "servers" => [ { "url" => "http://#{container_name}:6080" } ]
            }
          },
          # x11vnc native WebSocket (bypasses websockify translation layer)
          "vnc-ws-#{id}" => {
            "loadBalancer" => {
              "servers" => [ { "url" => "http://#{sandbox_name}:5901" } ]
            }
          }
        }
      }
    }

    File.write(File.join(DYNAMIC_DIR, "vnc-#{id}.yml"), config.to_yaml)
  end

  def tls_config
    if ENV["SANDCASTLE_TLS_MODE"] == "selfsigned"
      {}
    else
      { "certResolver" => "letsencrypt" }
    end
  end

  def delete_traefik_config(sandbox)
    path = File.join(DYNAMIC_DIR, "vnc-#{sandbox.id}.yml")
    File.delete(path) if File.exist?(path)
  end
end
