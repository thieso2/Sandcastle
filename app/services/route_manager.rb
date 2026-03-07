class RouteManager
  DATA_DIR = ENV.fetch("SANDCASTLE_DATA_DIR", "/data")
  DYNAMIC_DIR = File.join(DATA_DIR, "traefik", "dynamic")
  NETWORK_NAME = "sandcastle-web"

  TCP_PORT_MIN = ENV.fetch("SANDCASTLE_TCP_PORT_MIN", 3000).to_i
  TCP_PORT_MAX = ENV.fetch("SANDCASTLE_TCP_PORT_MAX", 3099).to_i
  TCP_PORT_RANGE = (TCP_PORT_MIN..TCP_PORT_MAX)

  TRAEFIK_STATIC_CONFIG = ENV.fetch("SANDCASTLE_TRAEFIK_CONFIG", File.join(DATA_DIR, "traefik", "traefik.yml"))
  TRAEFIK_CONTAINER = ENV.fetch("SANDCASTLE_TRAEFIK_CONTAINER", "sandcastle-traefik")

  class Error < StandardError; end

  def add_route(sandbox:, domain: nil, port: 8080, mode: "http")
    raise Error, "Sandbox is not running" unless sandbox.status == "running"

    route = Route.transaction do
      if mode == "tcp"
        public_port = allocate_tcp_port
        sandbox.routes.create!(mode: "tcp", port: port, public_port: public_port)
      else
        sandbox.routes.create!(mode: "http", domain: domain, port: port)
      end
    end

    if mode == "tcp"
      ensure_tcp_entrypoint(route.public_port)
    end

    ensure_network
    connect_to_network(sandbox)
    write_config(sandbox)

    route
  rescue ActiveRecord::RecordInvalid => e
    raise Error, e.message
  end

  def remove_route(route:)
    sandbox = route.sandbox
    route.destroy!

    if sandbox.routes.reload.any?
      write_config(sandbox)
    else
      delete_config(sandbox)
      disconnect_from_network(sandbox)
    end
  end

  def remove_all_routes(sandbox:)
    return unless sandbox.routed?

    sandbox.routes.destroy_all
    delete_config(sandbox)
    disconnect_from_network(sandbox)
  end

  def suspend_routes(sandbox:)
    return unless sandbox.routed?

    delete_config(sandbox)
    disconnect_from_network(sandbox)
  end

  def reconnect_routes(sandbox:)
    return unless sandbox.routed?

    ensure_network
    connect_to_network(sandbox)
    write_config(sandbox)
  end

  def sync_all_configs
    FileUtils.mkdir_p(DYNAMIC_DIR)

    active_ids = Sandbox.active.running.joins(:routes).distinct.pluck(:id).to_set

    # Remove stale config files
    Dir.glob(File.join(DYNAMIC_DIR, "sandbox-*.yml")).each do |path|
      id = File.basename(path, ".yml").delete_prefix("sandbox-").to_i
      unless active_ids.include?(id)
        File.delete(path)
        Rails.logger.info("RouteManager: removed stale config #{File.basename(path)}")
      end
    end

    # Regenerate configs for active routed sandboxes
    Sandbox.active.running.joins(:routes).distinct.includes(:user, :routes).find_each do |sandbox|
      ensure_network
      connect_to_network(sandbox)
      write_config(sandbox)
    end
  end

  def write_rails_config(host:)
    FileUtils.mkdir_p(DYNAMIC_DIR)

    # Build host list: main host + optional alternative hostnames
    hosts = [ host ]
    alt_hostnames = ENV["SANDCASTLE_ALT_HOSTNAMES"].to_s.split(",").map(&:strip).reject(&:empty?)
    hosts += alt_hostnames

    host_rules = hosts.map { |h| "`#{h}`" }.join(", ")
    rule = "Host(#{host_rules})"

    config = {
      "http" => {
        "routers" => {
          "rails-http" => {
            "rule" => rule,
            "service" => "rails",
            "entryPoints" => [ "web" ]
          },
          "rails-https" => {
            "rule" => rule,
            "service" => "rails",
            "entryPoints" => [ "websecure" ],
            "tls" => tls_config
          }
        },
        "services" => {
          "rails" => {
            "loadBalancer" => {
              "servers" => [ { "url" => "http://sandcastle-web:80" } ]
            }
          }
        }
      }
    }

    File.write(File.join(DYNAMIC_DIR, "rails.yml"), config.to_yaml)
    write_tls_config
  end

  private

  SELFSIGNED_MODES = %w[selfsigned mkcert].freeze

  def write_tls_config
    tls_path = File.join(DYNAMIC_DIR, "tls.yml")

    if SELFSIGNED_MODES.include?(ENV["SANDCASTLE_TLS_MODE"])
      # Traefik-perspective path (referenced inside tls.yml)
      cert_dir = ENV.fetch("SANDCASTLE_TLS_CERT_DIR", "/data/certs")
      # Rails-perspective path (where we can actually write files)
      local_cert_dir = File.join(DATA_DIR, "traefik", "certs")

      case ENV["SANDCASTLE_TLS_MODE"]
      when "selfsigned" then ensure_selfsigned_cert(local_cert_dir)
      when "mkcert"     then ensure_mkcert_cert(local_cert_dir)
      end

      certs = [ { "certFile" => "#{cert_dir}/cert.pem", "keyFile" => "#{cert_dir}/key.pem" } ]

      if custom_cert_configured?
        certs << { "certFile" => "/data/certs/custom-cert.pem", "keyFile" => "/data/certs/custom-key.pem" }
      end

      tls_config = {
        "tls" => {
          "certificates" => certs,
          "stores" => {
            "default" => {
              "defaultCertificate" => {
                "certFile" => "#{cert_dir}/cert.pem",
                "keyFile" => "#{cert_dir}/key.pem"
              }
            }
          }
        }
      }
      File.write(tls_path, tls_config.to_yaml)
    else
      File.delete(tls_path) if File.exist?(tls_path)
    end
  end

  def ensure_selfsigned_cert(cert_dir)
    cert_path = File.join(cert_dir, "cert.pem")
    key_path  = File.join(cert_dir, "key.pem")
    return if File.exist?(cert_path) && File.exist?(key_path)

    host = ENV.fetch("SANDCASTLE_HOST", "localhost")
    Rails.logger.info("RouteManager: generating self-signed certificate for #{host}")

    key  = OpenSSL::PKey::RSA.generate(4096)
    cert = OpenSSL::X509::Certificate.new
    cert.version    = 2
    cert.serial     = OpenSSL::BN.rand(128)
    cert.subject    = OpenSSL::X509::Name.parse("/CN=#{host}")
    cert.issuer     = cert.subject
    cert.public_key = key.public_key
    cert.not_before = Time.now
    cert.not_after  = Time.now + 10 * 365 * 24 * 60 * 60

    ef = OpenSSL::X509::ExtensionFactory.new
    ef.subject_certificate = cert
    ef.issuer_certificate  = cert

    san = host.match?(/\A[\d.]+\z/) ? "IP:#{host}" : "DNS:#{host}"
    san += ",IP:127.0.0.1,DNS:localhost"
    cert.add_extension(ef.create_extension("subjectAltName", san))
    cert.add_extension(ef.create_extension("basicConstraints", "CA:FALSE", true))
    cert.add_extension(ef.create_extension("keyUsage", "digitalSignature,keyEncipherment", true))
    cert.sign(key, OpenSSL::Digest::SHA256.new)

    FileUtils.mkdir_p(cert_dir)
    File.write(key_path,  key.to_pem,  perm: 0o600)
    File.write(cert_path, cert.to_pem, perm: 0o644)
    Rails.logger.info("RouteManager: self-signed certificate written to #{cert_path}")
  end

  def ensure_mkcert_cert(cert_dir)
    cert_path = File.join(cert_dir, "cert.pem")
    key_path  = File.join(cert_dir, "key.pem")
    return if File.exist?(cert_path) && File.exist?(key_path)

    host = ENV.fetch("SANDCASTLE_HOST", "localhost")
    Rails.logger.info("RouteManager: generating mkcert certificate for #{host}")

    # Store CA alongside the certs so it survives container restarts
    caroot = ENV.fetch("MKCERT_CAROOT", cert_dir)
    FileUtils.mkdir_p(cert_dir)

    env = { "CAROOT" => caroot }
    system(
      env,
      "mkcert",
      "-cert-file", cert_path,
      "-key-file",  key_path,
      host, "*.#{host}", "localhost", "127.0.0.1", "::1"
    ) or raise Error, "mkcert certificate generation failed for #{host}"

    ca_source = File.join(caroot, "rootCA.pem")
    ca_dest   = File.join(cert_dir, "rootCA.pem")
    FileUtils.cp(ca_source, ca_dest) if File.exist?(ca_source) && File.expand_path(ca_source) != File.expand_path(ca_dest)

    Rails.logger.info("RouteManager: mkcert certificate written to #{cert_path}")
  end

  def custom_cert_configured?
    cert_path = File.join(DATA_DIR, "traefik", "certs", "custom-cert.pem")
    key_path = File.join(DATA_DIR, "traefik", "certs", "custom-key.pem")
    File.exist?(cert_path) && File.exist?(key_path)
  end

  def config_path(sandbox)
    File.join(DYNAMIC_DIR, "sandbox-#{sandbox.id}.yml")
  end

  def write_config(sandbox)
    FileUtils.mkdir_p(DYNAMIC_DIR)

    routes = sandbox.routes.reload
    http_routers = {}
    http_services = {}
    tcp_routers = {}
    tcp_services = {}

    routes.each do |route|
      if route.http?
        key = "sandbox-#{sandbox.id}-r#{route.id}"
        http_routers[key] = {
          "rule" => "Host(`#{route.domain}`)",
          "service" => key,
          "entryPoints" => [ "websecure" ],
          "tls" => tls_config
        }
        http_services[key] = {
          "loadBalancer" => {
            "servers" => [ { "url" => "http://#{sandbox.full_name}:#{route.port}" } ]
          }
        }
      else
        key = "sandbox-#{sandbox.id}-tcp-r#{route.id}"
        tcp_routers[key] = {
          "rule" => "HostSNI(`*`)",
          "entryPoints" => [ "tcp-#{route.public_port}" ],
          "service" => key
        }
        tcp_services[key] = {
          "loadBalancer" => {
            "servers" => [ { "address" => "#{sandbox.full_name}:#{route.port}" } ]
          }
        }
      end
    end

    config = {}
    if http_routers.any?
      config["http"] = { "routers" => http_routers, "services" => http_services }
    end
    if tcp_routers.any?
      config["tcp"] = { "routers" => tcp_routers, "services" => tcp_services }
    end

    File.write(config_path(sandbox), config.to_yaml)
  end

  def tls_config
    if SELFSIGNED_MODES.include?(ENV["SANDCASTLE_TLS_MODE"])
      {}
    else
      { "certResolver" => "letsencrypt" }
    end
  end

  def delete_config(sandbox)
    path = config_path(sandbox)
    File.delete(path) if File.exist?(path)
  end

  def allocate_tcp_port
    used = Route.where(mode: "tcp").lock.pluck(:public_port).to_set
    TCP_PORT_RANGE.find { |p| !used.include?(p) } ||
      raise(Error, "No TCP ports available (pool #{TCP_PORT_MIN}–#{TCP_PORT_MAX} exhausted)")
  end

  def ensure_tcp_entrypoint(port)
    return unless File.exist?(TRAEFIK_STATIC_CONFIG)

    config = YAML.safe_load(File.read(TRAEFIK_STATIC_CONFIG)) || {}
    entry_key = "tcp-#{port}"

    entry_points = config["entryPoints"] ||= {}
    return if entry_points.key?(entry_key)

    entry_points[entry_key] = { "address" => ":#{port}" }
    File.write(TRAEFIK_STATIC_CONFIG, config.to_yaml)
    Rails.logger.info("RouteManager: added Traefik entrypoint #{entry_key}, restarting #{TRAEFIK_CONTAINER}")

    container = Docker::Container.get(TRAEFIK_CONTAINER)
    container.restart
  rescue Docker::Error::NotFoundError
    Rails.logger.warn("RouteManager: Traefik container #{TRAEFIK_CONTAINER} not found, skipping restart")
  rescue Errno::ENOENT, Errno::EACCES => e
    Rails.logger.warn("RouteManager: could not update Traefik static config: #{e.message}")
  end

  def ensure_network
    Docker::Network.get(NETWORK_NAME)
  rescue Docker::Error::NotFoundError
    Docker::Network.create(NETWORK_NAME, "Driver" => "bridge")
  end

  def connect_to_network(sandbox)
    return unless sandbox.container_id.present?

    network = Docker::Network.get(NETWORK_NAME)
    container = Docker::Container.get(sandbox.container_id)

    # Check if already connected
    networks = container.json.dig("NetworkSettings", "Networks") || {}
    return if networks.key?(NETWORK_NAME)

    network.connect(sandbox.container_id)
  rescue Docker::Error::DockerError => e
    raise Error, "Failed to connect container to network: #{e.message}"
  end

  def disconnect_from_network(sandbox)
    return unless sandbox.container_id.present?

    network = Docker::Network.get(NETWORK_NAME)
    network.disconnect(sandbox.container_id)
  rescue Docker::Error::NotFoundError
    # Network or container already gone
  rescue Docker::Error::DockerError
    # Container may not be connected
  end
end
