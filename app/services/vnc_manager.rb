class VncManager
  DATA_DIR = ENV.fetch("SANDCASTLE_DATA_DIR", "/data")
  NETWORK_NAME = "sandcastle-web"
  DYNAMIC_DIR = File.join(DATA_DIR, "traefik", "dynamic")

  class Error < StandardError; end

  # Opens a web-based VNC session for the given sandbox.
  # Returns the URL path to the noVNC session.
  # websockify runs inside the sandbox container (started by entrypoint.sh),
  # so we only need to connect the sandbox to the Traefik network and write
  # the Traefik routing config.
  def open(sandbox:)
    raise Error, "Sandbox is not running" unless sandbox.status == "running"
    raise Error, "Sandbox has no container" if sandbox.container_id.blank?

    ensure_network
    connect_sandbox_to_network(sandbox)
    write_traefik_config(sandbox)

    vnc_url(sandbox)
  rescue Docker::Error::DockerError => e
    raise Error, "Failed to open browser: #{e.message}"
  rescue SystemCallError => e
    raise Error, "Failed to open browser: #{e.message}"
  end

  # Closes the web VNC session for the given sandbox.
  def close(sandbox:)
    delete_traefik_config(sandbox)
  rescue Docker::Error::DockerError => e
    Rails.logger.error("VncManager: close failed for #{sandbox.full_name}: #{e.message}")
  end

  # Returns true if the sandbox's websockify process is accepting connections.
  # Requires the sandbox to already be connected to the sandcastle-web network
  # (i.e., after open has been called).
  def active?(sandbox:)
    return false unless File.exist?(traefik_config_path(sandbox))

    TCPSocket.new(sandbox.full_name, 6080).close
    true
  rescue Errno::ECONNREFUSED, Errno::ETIMEDOUT, SocketError
    false
  end

  # Removes orphaned Traefik VNC configs whose sandbox is gone or not running.
  def cleanup_orphaned
    Dir.glob(File.join(DYNAMIC_DIR, "vnc-*.yml")).each do |path|
      id = path.match(/vnc-(\d+)\.yml/)&.[](1)&.to_i
      next unless id

      sandbox = Sandbox.find_by(id: id)
      if sandbox.nil? || sandbox.status != "running"
        File.delete(path)
        Rails.logger.info("VncManager: removed orphaned Traefik config #{File.basename(path)}")
      end
    end
  rescue => e
    Rails.logger.error("VncManager: orphan cleanup failed: #{e.message}")
  end

  def prepare_traefik_config(sandbox)
    write_traefik_config(sandbox)
  end

  private

  def vnc_url(sandbox)
    id = sandbox.id
    "/vnc/#{id}/vnc.html?path=vnc/#{id}/websockify&autoconnect=true"
  end

  def traefik_config_path(sandbox)
    File.join(DYNAMIC_DIR, "vnc-#{sandbox.id}.yml")
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
    raise Error, "Sandbox container not found. Please refresh and try again."
  end

  def write_traefik_config(sandbox)
    FileUtils.mkdir_p(DYNAMIC_DIR)
    config_path = traefik_config_path(sandbox)
    return if File.exist?(config_path)

    host = ENV.fetch("SANDCASTLE_HOST", "localhost")
    id = sandbox.id
    sandbox_name = sandbox.full_name

    base_rule = if ENV["SANDCASTLE_TLS_MODE"] == "selfsigned"
      "HostRegexp(`.+`) && PathPrefix(`/vnc/#{id}`)"
    else
      "Host(`#{host}`) && PathPrefix(`/vnc/#{id}`)"
    end

    # Route all /vnc/{id} traffic to the sandbox container's websockify process
    # on port 6080. websockify serves noVNC static files and proxies WebSocket
    # connections to Xvnc on localhost:5900 inside the sandbox.
    # stripPrefix removes /vnc/{id} so websockify sees /websockify and /vnc.html.
    config = {
      "http" => {
        "routers" => {
          "vnc-#{id}" => {
            "rule" => base_rule,
            "service" => "vnc-#{id}",
            "entryPoints" => [ "websecure" ],
            "tls" => tls_config,
            "middlewares" => [ "vnc-auth-#{id}", "vnc-stripprefix-#{id}" ],
            "priority" => 100
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
              "prefixes" => [ "/vnc/#{id}" ]
            }
          }
        },
        "services" => {
          "vnc-#{id}" => {
            "loadBalancer" => {
              "servers" => [ { "url" => "http://#{sandbox_name}:6080" } ]
            }
          }
        }
      }
    }

    File.write(config_path, config.to_yaml)
  end

  def tls_config
    if ENV["SANDCASTLE_TLS_MODE"] == "selfsigned"
      {}
    else
      { "certResolver" => "letsencrypt" }
    end
  end

  def delete_traefik_config(sandbox)
    path = traefik_config_path(sandbox)
    File.delete(path) if File.exist?(path)
  end
end
