class RouteManager
  DATA_DIR = ENV.fetch("SANDCASTLE_DATA_DIR", "/data")
  DYNAMIC_DIR = File.join(DATA_DIR, "traefik", "dynamic")
  NETWORK_NAME = "sandcastle-web"

  class Error < StandardError; end

  def add_route(sandbox:, domain:, port: 8080)
    raise Error, "Sandbox is not running" unless sandbox.status == "running"

    route = sandbox.routes.create!(domain: domain, port: port)

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

    rule = if ENV["SANDCASTLE_TLS_MODE"] == "selfsigned"
      "HostRegexp(`.+`)"
    else
      "Host(`#{host}`)"
    end

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
  end

  private

  def config_path(sandbox)
    File.join(DYNAMIC_DIR, "sandbox-#{sandbox.id}.yml")
  end

  def write_config(sandbox)
    FileUtils.mkdir_p(DYNAMIC_DIR)

    routes = sandbox.routes.reload
    routers = {}
    services = {}

    routes.each do |route|
      key = "sandbox-#{sandbox.id}-r#{route.id}"
      routers[key] = {
        "rule" => "Host(`#{route.domain}`)",
        "service" => key,
        "entryPoints" => [ "websecure" ],
        "tls" => tls_config
      }
      services[key] = {
        "loadBalancer" => {
          "servers" => [ { "url" => "http://#{sandbox.full_name}:#{route.port}" } ]
        }
      }
    end

    config = { "http" => { "routers" => routers, "services" => services } }
    File.write(config_path(sandbox), config.to_yaml)
  end

  def tls_config
    if ENV["SANDCASTLE_TLS_MODE"] == "selfsigned"
      {}
    else
      { "certResolver" => "letsencrypt" }
    end
  end

  def delete_config(sandbox)
    path = config_path(sandbox)
    File.delete(path) if File.exist?(path)
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
