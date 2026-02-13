class TerminalManager
  DATA_DIR = ENV.fetch("SANDCASTLE_DATA_DIR", "/data")
  WETTY_IMAGE = ENV.fetch("SANDCASTLE_WETTY_IMAGE", "wettyoss/wetty:latest")
  NETWORK_NAME = "sandcastle-web"
  DYNAMIC_DIR = File.join(DATA_DIR, "traefik", "dynamic")

  class Error < StandardError; end

  # Opens a web terminal for the given sandbox.
  # Returns the URL path to the WeTTY session.
  def open(sandbox:)
    raise Error, "Sandbox is not running" unless sandbox.status == "running"
    raise Error, "Sandbox has no container" if sandbox.container_id.blank?

    user = sandbox.user
    container_name = wetty_container_name(sandbox)

    # Idempotent: if WeTTY container already running, return URL
    if container_running?(container_name)
      return wetty_url(sandbox)
    end

    pull_image
    ensure_network
    connect_sandbox_to_network(sandbox)

    # Write Traefik config early so it has time to detect the new route
    # while we set up keypairs and start the WeTTY container.
    write_traefik_config(sandbox)

    key_dir = generate_keypair(sandbox)
    inject_pubkey(sandbox, key_dir)
    create_wetty_container(sandbox: sandbox, user: user, key_dir: key_dir)

    # Give Traefik a moment to load the dynamic config before redirecting.
    sleep 1

    wetty_url(sandbox)
  rescue Docker::Error::DockerError => e
    raise Error, "Failed to open terminal: #{e.message}"
  rescue SystemCallError => e
    raise Error, "Failed to open terminal: #{e.message}"
  end

  # Closes the web terminal for the given sandbox.
  def close(sandbox:)
    container_name = wetty_container_name(sandbox)

    # Stop and remove WeTTY container
    begin
      container = Docker::Container.get(container_name)
      container.stop(t: 3) rescue nil
      container.delete(force: true)
    rescue Docker::Error::NotFoundError
      # Already gone
    end

    # Delete Traefik config
    delete_traefik_config(sandbox)

    # Clean up key directory
    key_dir = key_dir_path(sandbox)
    FileUtils.rm_rf(key_dir)

    # Best-effort: remove pubkey from sandbox authorized_keys
    remove_pubkey(sandbox)
  rescue Docker::Error::DockerError => e
    Rails.logger.error("TerminalManager: close failed for #{sandbox.full_name}: #{e.message}")
  end

  # Returns true if the WeTTY container is running for this sandbox.
  def active?(sandbox:)
    container_running?(wetty_container_name(sandbox))
  end

  # Removes orphaned WeTTY containers whose sandbox no longer exists or is not running.
  def cleanup_orphaned
    Docker::Container.all(all: true).each do |container|
      name = container.info.dig("Names")&.first&.delete_prefix("/")
      next unless name&.start_with?("sc-wetty-")

      labels = container.info["Labels"] || {}
      sandbox_id = labels["sandcastle.sandbox_id"]&.to_i

      sandbox = sandbox_id ? Sandbox.find_by(id: sandbox_id) : nil
      should_remove = sandbox.nil? || sandbox.status != "running"

      if should_remove
        container.stop(t: 3) rescue nil
        container.delete(force: true)
        Rails.logger.info("TerminalManager: removed orphaned WeTTY container #{name}")

        # Clean up Traefik config and keys if we have a sandbox_id
        if sandbox_id
          config_path = File.join(DYNAMIC_DIR, "terminal-#{sandbox_id}.yml")
          File.delete(config_path) if File.exist?(config_path)
        end

        # Extract full_name from container name and validate format
        full_name = name.delete_prefix("sc-wetty-")
        unless full_name.match?(/\A[a-z][a-z0-9_-]+-[a-z][a-z0-9_-]*\z/)
          Rails.logger.warn("TerminalManager: skipping suspicious container name: #{name}")
          next
        end

        key_dir = File.join(DATA_DIR, "wetty", full_name)
        expected_parent = File.join(DATA_DIR, "wetty")
        unless File.expand_path(key_dir).start_with?("#{File.expand_path(expected_parent)}/")
          Rails.logger.warn("TerminalManager: path traversal attempt detected: #{key_dir}")
          next
        end

        FileUtils.rm_rf(key_dir) if Dir.exist?(key_dir)
      end
    end
  rescue Docker::Error::DockerError => e
    Rails.logger.error("TerminalManager: orphan cleanup failed: #{e.message}")
  end

  private

  def wetty_container_name(sandbox)
    "sc-wetty-#{sandbox.full_name}"
  end

  def wetty_url(sandbox)
    "/terminal/#{sandbox.id}/wetty"
  end

  def key_dir_path(sandbox)
    File.join(DATA_DIR, "wetty", sandbox.full_name)
  end

  def container_running?(name)
    container = Docker::Container.get(name)
    container.json.dig("State", "Running") == true
  rescue Docker::Error::NotFoundError
    false
  end

  def pull_image
    Docker::Image.get(WETTY_IMAGE)
  rescue Docker::Error::NotFoundError
    Docker::Image.create("fromImage" => WETTY_IMAGE)
  rescue Docker::Error::DockerError
    raise Error, "Failed to pull #{WETTY_IMAGE} — check network connectivity"
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
  end

  def generate_keypair(sandbox)
    key_dir = key_dir_path(sandbox)
    FileUtils.mkdir_p(key_dir, mode: 0o700)

    key_path = File.join(key_dir, "key")
    # Remove old keys if they exist
    FileUtils.rm_f(key_path)
    FileUtils.rm_f("#{key_path}.pub")

    system("ssh-keygen", "-t", "ed25519", "-f", key_path, "-N", "", "-q", "-C", "wetty-#{sandbox.full_name}",
      exception: true)

    # Ensure private key is only readable by owner
    File.chmod(0o600, key_path)

    key_dir
  end

  def inject_pubkey(sandbox, key_dir)
    pubkey = File.read(File.join(key_dir, "key.pub")).strip
    username = sandbox.user.name

    container = Docker::Container.get(sandbox.container_id)

    # Write pubkey via base64 to avoid any shell-injection risk.
    # The stdin: approach hangs because docker-api never sends EOF to cat.
    encoded = Base64.strict_encode64("#{pubkey}\n")
    container.exec([ "mkdir", "-p", "/home/#{username}/.ssh" ])
    container.exec([ "sh", "-c", "echo #{encoded} | base64 -d >> /home/#{username}/.ssh/authorized_keys" ])
    container.exec([ "chown", "-R", "#{username}:#{username}", "/home/#{username}/.ssh" ])
    container.exec([ "chmod", "600", "/home/#{username}/.ssh/authorized_keys" ])
  end

  def create_wetty_container(sandbox:, user:, key_dir:)
    container_name = wetty_container_name(sandbox)

    # Remove any existing container with this name
    begin
      old = Docker::Container.get(container_name)
      old.stop(t: 3) rescue nil
      old.delete(force: true)
    rescue Docker::Error::NotFoundError
      # No existing container
    end

    ssh_command = [
      "ssh", "-p", "22",
      "-o", "StrictHostKeyChecking=no",
      "-o", "UserKnownHostsFile=/dev/null",
      "-o", "LogLevel=ERROR",
      "-i", "/etc/wetty/key",
      "#{user.name}@#{sandbox.full_name}",
      "-t", "tmux new-session -A -s main"
    ].join(" ")

    container = Docker::Container.create(
      "name" => container_name,
      "Image" => WETTY_IMAGE,
      "Env" => [
        "COMMAND=#{ssh_command}",
        "BASE=/terminal/#{sandbox.id}/wetty"
      ],
      "HostConfig" => {
        "NetworkMode" => NETWORK_NAME,
        "RestartPolicy" => { "Name" => "no" },
        "Memory" => 128 * 1024 * 1024, # 128MB
        "NanoCpus" => 500_000_000 # 0.5 CPU
      },
      "Labels" => {
        "sandcastle.sandbox_id" => sandbox.id.to_s,
        "sandcastle.role" => "wetty"
      }
    )

    container.start
    copy_key_to_container(container, key_dir)
    container
  end

  # Copy the SSH private key into the WeTTY container via exec + base64.
  # This avoids bind-mount path issues when Rails runs inside a container
  # with a Docker volume for /data (the host path doesn't match).
  def copy_key_to_container(container, key_dir)
    key_content = File.read(File.join(key_dir, "key"))
    encoded = Base64.strict_encode64(key_content)

    container.exec([ "mkdir", "-p", "/etc/wetty" ])
    container.exec([ "sh", "-c", "echo #{encoded} | base64 -d > /etc/wetty/key" ])
    container.exec([ "chmod", "600", "/etc/wetty/key" ])
  end

  def write_traefik_config(sandbox)
    FileUtils.mkdir_p(DYNAMIC_DIR)

    host = ENV.fetch("SANDCASTLE_HOST", "localhost")
    id = sandbox.id
    container_name = wetty_container_name(sandbox)

    rule = if ENV["SANDCASTLE_TLS_MODE"] == "selfsigned"
      "HostRegexp(`.+`) && PathPrefix(`/terminal/#{id}/wetty`)"
    else
      "Host(`#{host}`) && PathPrefix(`/terminal/#{id}/wetty`)"
    end

    config = {
      "http" => {
        "routers" => {
          "terminal-#{id}" => {
            "rule" => rule,
            "service" => "terminal-#{id}",
            "entryPoints" => [ "websecure" ],
            "tls" => tls_config,
            "middlewares" => [ "terminal-auth-#{id}" ],
            "priority" => 100
          }
        },
        "middlewares" => {
          "terminal-auth-#{id}" => {
            "forwardAuth" => {
              "address" => "http://sandcastle-web:80/terminal/auth",
              "trustForwardHeader" => true
            }
          }
        },
        "services" => {
          "terminal-#{id}" => {
            "loadBalancer" => {
              "servers" => [ { "url" => "http://#{container_name}:3000" } ]
            }
          }
        }
      }
    }

    File.write(File.join(DYNAMIC_DIR, "terminal-#{id}.yml"), config.to_yaml)
  end

  def tls_config
    if ENV["SANDCASTLE_TLS_MODE"] == "selfsigned"
      {}
    else
      { "certResolver" => "letsencrypt" }
    end
  end

  def delete_traefik_config(sandbox)
    path = File.join(DYNAMIC_DIR, "terminal-#{sandbox.id}.yml")
    File.delete(path) if File.exist?(path)
  end

  def remove_pubkey(sandbox)
    return unless sandbox.container_id.present?

    begin
      container = Docker::Container.get(sandbox.container_id)
      username = sandbox.user.name
      # Match end-of-line to avoid substring collisions
      # (e.g. "wetty-user-foo" must not also remove "wetty-user-foobar").
      # Sandbox names are [a-z0-9_-] only, so safe for regex.
      marker = "wetty-#{sandbox.full_name}$"
      container.exec([
        "sh", "-c",
        "grep -v '#{marker}' /home/#{username}/.ssh/authorized_keys > /tmp/ak_clean && " \
        "mv /tmp/ak_clean /home/#{username}/.ssh/authorized_keys || true"
      ])
    rescue Docker::Error::NotFoundError, Docker::Error::DockerError
      # Sandbox container gone or exec failed — best-effort
    end
  end
end
