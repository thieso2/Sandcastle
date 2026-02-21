class TerminalManager
  DATA_DIR     = ENV.fetch("SANDCASTLE_DATA_DIR", "/data")
  NETWORK_NAME = "sandcastle-web"
  DYNAMIC_DIR  = File.join(DATA_DIR, "traefik", "dynamic")
  TRAEFIK_PICKUP_DELAY = 0.3 # seconds Traefik needs to pick up a new file config

  TMUX_PORT  = 7681
  SHELL_PORT = 7682

  class Error < StandardError; end

  # Opens a web terminal for the given sandbox.
  # type: "tmux" (default) or "shell"
  # Writes Traefik config (idempotent) and returns the terminal URL.
  # Returns [url, newly_written] — newly_written is true when the Traefik
  # config was just created (Traefik hasn't loaded it yet), false when it
  # already existed (Traefik already has the route active).
  def open(sandbox:, type: "tmux")
    raise Error, "Sandbox is not running" unless sandbox.status == "running"

    newly_written = write_traefik_config(sandbox)
    [ terminal_url(sandbox, type), newly_written ]
  end

  # Returns true if ttyd is listening on the appropriate port inside the sandbox container.
  # Uses docker exec + ss to check from inside the container — works in both dev (host Rails)
  # and production (Rails in Docker) without needing Docker network hostname resolution.
  def active?(sandbox:, type: "tmux")
    return false if sandbox.container_id.blank?

    port = type == "shell" ? SHELL_PORT : TMUX_PORT
    container = Docker::Container.get(sandbox.container_id)
    _out, _err, code = container.exec([ "sh", "-c", "ss -tlnp 2>/dev/null | grep -q ':#{port}' || netstat -tlnp 2>/dev/null | grep -q ':#{port}'" ])
    code == 0
  rescue Docker::Error::NotFoundError, Docker::Error::DockerError => e
    Rails.logger.debug("TerminalManager#active? #{sandbox.full_name}:#{port} → #{e.class}: #{e.message}")
    false
  end

  # Returns true once Traefik has had time to pick up the dynamic config file.
  # Traefik's inotify watcher loads new files in < 300ms; we check the mtime.
  def traefik_ready?(sandbox:, type: "tmux")
    path = File.join(DYNAMIC_DIR, "terminal-#{sandbox.id}.yml")
    File.exist?(path) && (Time.now - File.mtime(path)) > TRAEFIK_PICKUP_DELAY
  end

  # Deletes the Traefik config for the given sandbox.
  def close(sandbox:)
    delete_traefik_config(sandbox)
  end

  # Scans terminal-*.yml files; removes configs for sandboxes that no longer exist or aren't running.
  def cleanup_orphaned
    Dir.glob(File.join(DYNAMIC_DIR, "terminal-*.yml")).each do |path|
      match = File.basename(path).match(/\Aterminal-(\d+)\.yml\z/)
      next unless match

      sandbox_id = match[1].to_i
      sandbox = Sandbox.find_by(id: sandbox_id)

      if sandbox.nil? || sandbox.status != "running"
        File.delete(path)
        Rails.logger.info("TerminalManager: removed orphaned Traefik config #{File.basename(path)}")
      end
    end
  end

  private

  def terminal_url(sandbox, type)
    "/terminal/#{sandbox.id}/#{type}"
  end

  def write_traefik_config(sandbox)
    FileUtils.mkdir_p(DYNAMIC_DIR)
    config_path = File.join(DYNAMIC_DIR, "terminal-#{sandbox.id}.yml")
    return false if File.exist?(config_path)

    host = ENV.fetch("SANDCASTLE_HOST", "localhost")
    id   = sandbox.id
    container = sandbox.full_name

    if ENV["SANDCASTLE_TLS_MODE"] == "selfsigned"
      tmux_rule  = "HostRegexp(`.+`) && PathPrefix(`/terminal/#{id}/tmux`)"
      shell_rule = "HostRegexp(`.+`) && PathPrefix(`/terminal/#{id}/shell`)"
    else
      tmux_rule  = "Host(`#{host}`) && PathPrefix(`/terminal/#{id}/tmux`)"
      shell_rule = "Host(`#{host}`) && PathPrefix(`/terminal/#{id}/shell`)"
    end

    config = {
      "http" => {
        "routers" => {
          "terminal-#{id}-tmux" => {
            "rule"        => tmux_rule,
            "service"     => "terminal-#{id}-tmux",
            "entryPoints" => [ "websecure" ],
            "tls"         => tls_config,
            "middlewares" => [ "terminal-auth-#{id}", "terminal-#{id}-strip-tmux" ],
            "priority"    => 100
          },
          "terminal-#{id}-shell" => {
            "rule"        => shell_rule,
            "service"     => "terminal-#{id}-shell",
            "entryPoints" => [ "websecure" ],
            "tls"         => tls_config,
            "middlewares" => [ "terminal-auth-#{id}", "terminal-#{id}-strip-shell" ],
            "priority"    => 100
          }
        },
        "middlewares" => {
          "terminal-auth-#{id}" => {
            "forwardAuth" => {
              "address"            => "http://sandcastle-web:80/terminal/auth",
              "trustForwardHeader" => true
            }
          },
          "terminal-#{id}-strip-tmux" => {
            "stripPrefix" => { "prefixes" => [ "/terminal/#{id}/tmux" ] }
          },
          "terminal-#{id}-strip-shell" => {
            "stripPrefix" => { "prefixes" => [ "/terminal/#{id}/shell" ] }
          }
        },
        "services" => {
          "terminal-#{id}-tmux" => {
            "loadBalancer" => {
              "servers" => [ { "url" => "http://#{container}:#{TMUX_PORT}" } ]
            }
          },
          "terminal-#{id}-shell" => {
            "loadBalancer" => {
              "servers" => [ { "url" => "http://#{container}:#{SHELL_PORT}" } ]
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
    path = File.join(DYNAMIC_DIR, "terminal-#{sandbox.id}.yml")
    File.delete(path) if File.exist?(path)
  end
end
