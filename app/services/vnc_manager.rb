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

  # Returns true if the noVNC container is running AND its HTTP server is ready.
  # The container_running? check alone is insufficient — the websockify process
  # may not have bound to port 6080 yet when Docker reports the container as running.
  def active?(sandbox:)
    container_name = vnc_container_name(sandbox)
    return false unless container_running?(container_name)

    TCPSocket.new(container_name, 6080).close
    true
  rescue Errno::ECONNREFUSED, Errno::ETIMEDOUT, SocketError
    false
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
    # Strip prefix is /vnc/{id}, so all requests under /vnc/{id}/* are forwarded
    # to the noVNC container with the prefix removed. This keeps noVNC's relative
    # asset paths (package.json, core/*.js) resolving correctly within the prefix.
    # The ?path= tells noVNC where to connect the WebSocket; Traefik strips
    # /vnc/{id} leaving /websockify which websockify handles.
    "/vnc/#{id}/vnc.html?path=vnc/#{id}/websockify&autoconnect=true"
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
      "Memory" => 128 * 1024 * 1024, # 128MB — noVNC static files + websockify proxy
      "NanoCpus" => 250_000_000 # 0.25 CPU
    }

    # Run the noVNC image using its built-in launch.sh, which starts both the
    # mini-webserver (noVNC HTML/JS) and websockify (WS→RFB proxy) on port 6080.
    # Traefik routes everything under /vnc/{id} to this container; after
    # stripPrefix the websockify path becomes /websockify as noVNC expects.
    container = Docker::Container.create(
      "name" => container_name,
      "Image" => NOVNC_IMAGE,
      "Cmd" => [ "--vnc", "#{sandbox.full_name}:5900", "--listen", "6080" ],
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
      "HostRegexp(`.+`) && PathPrefix(`/vnc/#{id}`)"
    else
      "Host(`#{host}`) && PathPrefix(`/vnc/#{id}`)"
    end

    # Single router: all traffic under /vnc/{id} goes to the noVNC sidecar.
    # The noVNC container (gotget/novnc launch.sh) serves static HTML/JS on /
    # and proxies WebSocket VNC frames via websockify on /websockify, both on
    # port 6080. stripPrefix removes /vnc/{id} before forwarding, so noVNC's
    # relative asset paths (package.json, core/*.js, /websockify) resolve correctly.
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
              "servers" => [ { "url" => "http://#{container_name}:6080" } ]
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
