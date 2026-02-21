class VncManager
  DATA_DIR    = ENV.fetch("SANDCASTLE_DATA_DIR", "/data")
  DYNAMIC_DIR = File.join(DATA_DIR, "traefik", "dynamic")
  TRAEFIK_PICKUP_DELAY = 0.3 # seconds Traefik needs to pick up a new file config

  class Error < StandardError; end

  # Opens a web-based VNC session for the given sandbox.
  # Returns the URL path to the noVNC session.
  # websockify runs inside the sandbox container (started by entrypoint.sh),
  # so we only need to connect the sandbox to the Traefik network and write
  # the Traefik routing config.
  def open(sandbox:)
    raise Error, "Sandbox is not running" unless sandbox.status == "running"

    write_traefik_config(sandbox)
    vnc_url(sandbox)
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

  # Returns true once Traefik has had time to pick up the dynamic config file.
  # Traefik's inotify watcher loads new files in < 300ms; we check the mtime.
  def traefik_ready?(sandbox:)
    File.exist?(traefik_config_path(sandbox)) &&
      (Time.now - File.mtime(traefik_config_path(sandbox))) > TRAEFIK_PICKUP_DELAY
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

  def vnc_url(sandbox)
    id = sandbox.id
    "/novnc/vnc.html?path=/vnc/#{id}/websockify&autoconnect=true"
  end

  private

  def traefik_config_path(sandbox)
    File.join(DYNAMIC_DIR, "vnc-#{sandbox.id}.yml")
  end

  def write_traefik_config(sandbox)
    FileUtils.mkdir_p(DYNAMIC_DIR)
    config_path = traefik_config_path(sandbox)
    return false if File.exist?(config_path)

    host = ENV.fetch("SANDCASTLE_HOST", "localhost")
    id = sandbox.id
    sandbox_name = sandbox.full_name

    base_rule = if ENV["SANDCASTLE_TLS_MODE"] == "selfsigned"
      "HostRegexp(`.+`) && PathPrefix(`/vnc/#{id}/websockify`)"
    else
      "Host(`#{host}`) && PathPrefix(`/vnc/#{id}/websockify`)"
    end

    # Route only the WebSocket path /vnc/{id}/websockify to websockify-go on port 6080.
    # noVNC static files (vnc.html, core/, etc.) are served from Rails public/novnc/.
    # stripPrefix removes /vnc/{id} so websockify-go receives /websockify.
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
    true
  end

  def tls_config
    case ENV["SANDCASTLE_TLS_MODE"]
    when "selfsigned", "mkcert"
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
