class TerminalManager
  DATA_DIR     = ENV.fetch("SANDCASTLE_DATA_DIR", "/data")
  NETWORK_NAME = "sandcastle-web"
  DYNAMIC_DIR  = File.join(DATA_DIR, "traefik", "dynamic")
  TMUX_PORT  = 7681
  SHELL_PORT = 7682

  class Error < StandardError; end

  # Opens a web terminal for the given sandbox.
  # type: "tmux" (default) or "shell"
  # Writes Traefik config (idempotent) and returns the terminal URL.
  def open(sandbox:, type: "tmux")
    raise Error, "Sandbox is not running" unless sandbox.status == "running"

    write_traefik_config(sandbox)
    terminal_url(sandbox, type)
  end

  # Pre-writes the Traefik config without requiring the sandbox to be open.
  # Called at container start so routes are ready immediately.
  def prepare_traefik_config(sandbox)
    write_traefik_config(sandbox)
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

    selfsigned = ENV["SANDCASTLE_TLS_MODE"] == "selfsigned"
    if selfsigned
      tmux_rule  = "HostRegexp(`.+`) && PathPrefix(`/terminal/#{id}/tmux`)"
      shell_rule = "HostRegexp(`.+`) && PathPrefix(`/terminal/#{id}/shell`)"
    else
      tmux_rule  = "Host(`#{host}`) && PathPrefix(`/terminal/#{id}/tmux`)"
      shell_rule = "Host(`#{host}`) && PathPrefix(`/terminal/#{id}/shell`)"
    end

    routers = {
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
    }

    # In dev (selfsigned mode) also expose the plain-HTTP entrypoint so the
    # terminal works without trusting the self-signed cert.
    if selfsigned
      routers["terminal-#{id}-tmux-http"] = routers["terminal-#{id}-tmux"].merge(
        "entryPoints" => [ "web" ]
      ).except("tls")
      routers["terminal-#{id}-shell-http"] = routers["terminal-#{id}-shell"].merge(
        "entryPoints" => [ "web" ]
      ).except("tls")
    end

    config = {
      "http" => {
        "routers" => routers,
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
