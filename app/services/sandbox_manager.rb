class SandboxManager
  DATA_DIR = ENV.fetch("SANDCASTLE_DATA_DIR", "/data")
  DEFAULT_IMAGE = "ghcr.io/thieso2/sandcastle-sandbox:latest"
  NETWORK_NAME = "sandcastle-web"

  class Error < StandardError; end

  def create(user:, name:, image: DEFAULT_IMAGE, tailscale: false, mount_home: false, data_path: nil, temporary: false)
    # Build sandbox record (not saved yet)
    sandbox = user.sandboxes.build(
      name: name,
      image: image,
      status: "pending",
      mount_home: mount_home,
      data_path: data_path,
      temporary: temporary
    )

    # Validate before doing expensive operations
    sandbox.validate!

    # Create directories FIRST (can fail fast before saving record)
    ensure_mount_dirs(user, sandbox)

    # Now safe to save
    sandbox.save!

    # Pull image
    ensure_image(image)

    # Create and start container
    create_container_and_start(sandbox: sandbox, user: user)

    # Connect to Tailscale if requested
    if (tailscale || user.tailscale_auto_connect?) && user.tailscale_enabled?
      TailscaleManager.new.connect_sandbox(sandbox: sandbox)
    end

    sandbox
  rescue Docker::Error::DockerError => e
    sandbox&.update(status: "destroyed") if sandbox&.persisted?
    raise Error, "Failed to create container: #{e.message}"
  rescue => e
    # If anything fails before save, no DB record is created
    # If anything fails after save, mark as destroyed
    sandbox&.update(status: "destroyed") if sandbox&.persisted?
    raise Error, e.message
  end

  # Public method for job usage
  def create_container_and_start(sandbox:, user:)
    container = Docker::Container.create(
      "name" => sandbox.full_name,
      "Image" => sandbox.image,
      "Hostname" => sandbox.full_name,
      "Env" => container_env(user, sandbox),
      "Labels" => { "sandcastle.sandbox" => "true" },
      "HostConfig" => {
        "Runtime" => container_runtime,
        "NetworkMode" => NETWORK_NAME,
        "Binds" => volume_binds(user, sandbox),
        "RestartPolicy" => { "Name" => "unless-stopped" }
      },
      "NetworkingConfig" => {
        "EndpointsConfig" => { NETWORK_NAME => {} }
      }
    )

    container.start
    container.refresh!
    unless container.json.dig("State", "Running")
      state_error = container.json.dig("State", "Error").presence || container.json.dig("State", "Status")
      container.stop rescue nil
      container.delete(force: true) rescue nil
      raise Error, "Container failed to start: #{state_error}"
    end
    sandbox.update!(container_id: container.id, status: "running")

    # Connect to per-user network for tenant isolation
    NetworkManager.new.connect_sandbox(sandbox: sandbox)

    # Pre-write Traefik routes so they're active immediately (no wait on first open).
    TerminalManager.new.prepare_traefik_config(sandbox)
    VncManager.new.prepare_traefik_config(sandbox) if sandbox.vnc_enabled?

    # Set SMB password via exec (avoids leaking password in container env/metadata)
    set_smb_password(container, sandbox.user) if sandbox.smb_enabled?
  end

  # Public method for job usage
  def ensure_image(image)
    Docker::Image.get(image)
  rescue Docker::Error::NotFoundError
    raise Error, "Snapshot image #{image} not found locally (snapshots are never pulled from a registry)" if image.start_with?("sc-snap-")
    Docker::Image.create("fromImage" => image)
  rescue Docker::Error::DockerError => e
    raise Error, "Failed to pull image #{image}: #{e.message}"
  end

  # Public method for job usage
  def ensure_mount_dirs(user, sandbox)
    # Create BTRFS subvolume for user directory if on BTRFS
    BtrfsHelper.create_user_subvolume(user.name)

    # Ensure user base directory is writable (may be root-owned from previous install)
    ensure_dir("#{DATA_DIR}/users/#{user.name}")

    if sandbox.mount_home
      dir = "#{DATA_DIR}/users/#{user.name}/home"
      ensure_dir(dir)
      prepare_bind_mount(dir)
    end
    if sandbox.data_path.present?
      # Create BTRFS subvolume for data directory if on BTRFS
      BtrfsHelper.create_user_data_subvolume(user.name, sandbox.data_path)

      dir = "#{DATA_DIR}/users/#{user.name}/data/#{sandbox.data_path}".chomp("/")
      ensure_dir(dir)
      prepare_bind_mount(dir)
    end
    # Chrome profile persistence: mount .config/google-chrome separately if not mounting full home
    if user.chrome_persist_profile? && !sandbox.mount_home
      dir = "#{DATA_DIR}/users/#{user.name}/chrome-profile"
      ensure_dir(dir)
      prepare_bind_mount(dir)
    end
  rescue Errno::EACCES, Errno::ENOENT => e
    raise Error, "Failed to create mount directories: #{e.message}"
  end

  def destroy(sandbox:, archive: false)
    begin
      TerminalManager.new.close(sandbox: sandbox)
    rescue TerminalManager::Error, Docker::Error::DockerError
      # best-effort terminal cleanup
    end

    begin
      VncManager.new.close(sandbox: sandbox)
    rescue VncManager::Error, Docker::Error::DockerError
      # best-effort VNC cleanup
    end

    RouteManager.new.remove_all_routes(sandbox: sandbox) if sandbox.routed?

    if sandbox.tailscale?
      TailscaleManager.new.disconnect_sandbox(sandbox: sandbox)
    end

    if sandbox.container_id.present?
      begin
        container = Docker::Container.get(sandbox.container_id)
        container.stop(t: 5) rescue nil
        container.delete(force: true)
      rescue Docker::Error::NotFoundError
        # Container already gone
      end
    end

    if archive
      # Soft-delete: keep volume on disk, mark as archived.
      # Rename to free the original name for reuse.
      archived_name = "#{Time.current.strftime('%Y%m%d%H%M%S')}-#{sandbox.name}"
      sandbox.update!(status: "archived", container_id: nil, archived_at: Time.current, name: archived_name)
    else
      sandbox.update!(status: "destroyed", container_id: nil)
    end

    # Remove per-user network if this was the last active sandbox
    begin
      NetworkManager.new.cleanup_user_network(sandbox.user)
    rescue NetworkManager::Error => e
      Rails.logger.warn("SandboxManager#destroy: network cleanup failed for #{sandbox.user.name}: #{e.message}")
    end
  end

  # Restore an archived sandbox: recreate the container from the existing volume.
  # The container is started immediately; status is set to "running".
  def restore_from_archive(sandbox:)
    raise Error, "Sandbox is not archived" unless sandbox.status == "archived"

    user = sandbox.user

    ensure_image(sandbox.image)
    ensure_mount_dirs(user, sandbox)

    create_container_and_start(sandbox: sandbox, user: user)
    # Strip the timestamp prefix added during archival (e.g. "20260307123456-mybox" → "mybox")
    original_name = sandbox.name.sub(/\A\d{14}-/, "")
    sandbox.update!(archived_at: nil, name: original_name)

    if sandbox.tailscale? && user.tailscale_enabled?
      TailscaleManager.new.connect_sandbox(sandbox: sandbox)
    end

    sandbox
  rescue Docker::Error::DockerError => e
    raise Error, "Failed to restore archived sandbox: #{e.message}"
  end

  def start(sandbox:)
    raise Error, "Sandbox is destroyed" if sandbox.status == "destroyed"
    return sandbox if sandbox.status == "running"

    user = sandbox.user

    if sandbox.container_id.present?
      begin
        old = Docker::Container.get(sandbox.container_id)
        old.stop(t: 5) rescue nil
        old.delete(force: true)
      rescue Docker::Error::NotFoundError
        # already gone
      end
    end

    # Reset bind-mount directory permissions before starting the new container.
    # After a previous Sysbox run, dirs may be owned by a remapped UID that
    # Rails can't chmod — ensure_mount_dirs uses sudo to reset to 777.
    ensure_mount_dirs(user, sandbox)

    create_container_and_start(sandbox: sandbox, user: user)

    TailscaleManager.new.connect_sandbox(sandbox: sandbox) if sandbox.tailscale? && user.tailscale_enabled?
    RouteManager.new.reconnect_routes(sandbox: sandbox) if sandbox.routed?

    sandbox
  rescue Docker::Error::NotFoundError
    sandbox.update!(status: "destroyed", container_id: nil)
    raise Error, "Container not found — sandbox must be recreated"
  end

  def stop(sandbox:)
    return sandbox if sandbox.status == "stopped"

    begin
      TerminalManager.new.close(sandbox: sandbox)
    rescue TerminalManager::Error, Docker::Error::DockerError
      # best-effort terminal cleanup
    end

    begin
      VncManager.new.close(sandbox: sandbox)
    rescue VncManager::Error, Docker::Error::DockerError
      # best-effort VNC cleanup
    end

    RouteManager.new.suspend_routes(sandbox: sandbox) if sandbox.routed?

    if sandbox.container_id.present?
      begin
        container = Docker::Container.get(sandbox.container_id)
        container.stop(t: 10)
      rescue Docker::Error::NotFoundError
        # already gone
      end
    end

    sandbox.update!(status: "stopped")
    sandbox
  end

  SERVICES = %w[docker vnc].freeze

  def service_start(sandbox:, service:)
    raise Error, "Unknown service: #{service}" unless SERVICES.include?(service)
    raise Error, "Sandbox has no container" if sandbox.container_id.blank?

    container = Docker::Container.get(sandbox.container_id)
    user = sandbox.user.name

    case service
    when "docker"
      container.exec([ "bash", "-c", "pgrep -x dockerd > /dev/null && echo already_running && exit 0; dockerd --storage-driver=overlay2 --mtu=$(ip link show eth0 2>/dev/null | grep -oP 'mtu \\K[0-9]+' || echo 1500) &>/var/log/dockerd.log & echo started" ])
    when "vnc"
      geometry = sandbox.vnc_geometry || "1280x900"
      depth = sandbox.vnc_depth || 24
      container.exec([ "bash", "-c", "pgrep -x Xvnc > /dev/null && echo already_running && exit 0; su -s /bin/bash #{user} -c 'Xvnc :99 -rfbport 5900 -SecurityTypes None -AlwaysShared -geometry #{geometry} -depth #{depth} &>/var/log/xvnc.log &' && su -s /bin/bash #{user} -c 'DISPLAY=:99 openbox &>/var/log/openbox.log &' && websockify -addr :6080 -target localhost:5900 -url /websockify &>/var/log/websockify.log & echo started" ])
    end
  rescue Docker::Error::NotFoundError
    raise Error, "Container not found"
  rescue Docker::Error::DockerError => e
    raise Error, "Failed to start #{service}: #{e.message}"
  end

  def service_stop(sandbox:, service:)
    raise Error, "Unknown service: #{service}" unless SERVICES.include?(service)
    raise Error, "Sandbox has no container" if sandbox.container_id.blank?

    container = Docker::Container.get(sandbox.container_id)

    case service
    when "docker"
      container.exec([ "bash", "-c", "pkill -x dockerd 2>/dev/null; pkill -x containerd 2>/dev/null; echo stopped" ])
    when "vnc"
      container.exec([ "bash", "-c", "pkill -x websockify 2>/dev/null; pkill -x openbox 2>/dev/null; pkill -x Xvnc 2>/dev/null; echo stopped" ])
    end
  rescue Docker::Error::NotFoundError
    raise Error, "Container not found"
  rescue Docker::Error::DockerError => e
    raise Error, "Failed to stop #{service}: #{e.message}"
  end

  def logs(sandbox:, tail: 200, timestamps: false)
    raise Error, "Sandbox has no container" if sandbox.container_id.blank?

    container = Docker::Container.get(sandbox.container_id)
    container.logs(stdout: true, stderr: true, follow: false, tail: tail, timestamps: timestamps)
      .force_encoding("UTF-8").encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
  rescue Docker::Error::NotFoundError
    raise Error, "Container not found"
  rescue Docker::Error::DockerError => e
    raise Error, "Failed to fetch logs: #{e.message}"
  end

  def status(sandbox:)
    return { state: "destroyed" } if sandbox.container_id.blank?

    container = Docker::Container.get(sandbox.container_id)
    info = container.json
    {
      state: info.dig("State", "Status"),
      running: info.dig("State", "Running"),
      started_at: info.dig("State", "StartedAt"),
      pid: info.dig("State", "Pid")
    }
  rescue Docker::Error::NotFoundError
    { state: "not_found" }
  end

  # Create a composite snapshot (Docker image + optional BTRFS layers).
  # Returns a Snapshot ActiveRecord object.
  #
  # layers: array of "container", "home", "data", "workspace"
  #   nil means "all available" based on sandbox config
  def create_snapshot(sandbox:, name:, label: nil, layers: nil, data_subdir: nil)
    raise Error, "Sandbox has no running container" if sandbox.container_id.blank?

    user = sandbox.user
    name = name.presence || Date.today.iso8601
    requested_layers = layers&.map(&:to_s) || %w[container home data]

    snap = Snapshot.new(
      user: user,
      name: name,
      label: label,
      source_sandbox: sandbox.name,
      data_subdir: data_subdir
    )

    # ── Container layer ──────────────────────────────────────────────────────
    if requested_layers.include?("container")
      repo = "sc-snap-#{user.name}"
      container = Docker::Container.get(sandbox.container_id)
      image = container.commit(
        repo: repo,
        tag: name,
        comment: "sandbox:#{sandbox.name}"
      )
      snap.docker_image = "#{repo}:#{name}"
      snap.docker_size  = image.info["Size"]
    end

    # ── Home layer (BTRFS only) ───────────────────────────────────────────────
    if requested_layers.include?("home") && sandbox.mount_home? && BtrfsHelper.btrfs?
      home_src  = "#{DATA_DIR}/users/#{user.name}/home"
      home_dest = "#{DATA_DIR}/snapshots/#{user.name}/#{name}/home"
      if Dir.exist?(home_src)
        BtrfsHelper.snapshot_subvolume(home_src, home_dest)
        snap.home_snapshot = home_dest
        snap.home_size     = BtrfsHelper.subvolume_size(home_dest)
      end
    end

    # ── Data layer (BTRFS only) ───────────────────────────────────────────────
    if requested_layers.include?("data") && sandbox.data_path.present? && BtrfsHelper.btrfs?
      if data_subdir.present?
        data_src  = "#{DATA_DIR}/users/#{user.name}/data/#{sandbox.data_path}/#{data_subdir}".chomp("/")
      else
        data_src  = "#{DATA_DIR}/users/#{user.name}/data/#{sandbox.data_path}".chomp("/")
      end
      data_dest = "#{DATA_DIR}/snapshots/#{user.name}/#{name}/data"
      if Dir.exist?(data_src)
        BtrfsHelper.snapshot_subvolume(data_src, data_dest)
        snap.data_snapshot = data_dest
        snap.data_size     = BtrfsHelper.subvolume_size(data_dest)
      end
    end

    snap.save!
    snap
  rescue Docker::Error::DockerError => e
    raise Error, "Failed to create snapshot: #{e.message}"
  rescue BtrfsHelper::Error => e
    raise Error, "Failed to snapshot filesystem layer: #{e.message}"
  end

  # Legacy alias kept for backward compatibility (used by existing API endpoint).
  def snapshot(sandbox:, name: nil, **opts)
    snap = create_snapshot(sandbox: sandbox, name: name, layers: %w[container])
    {
      name: snap.name,
      image: snap.docker_image,
      sandbox: snap.source_sandbox,
      created_at: snap.created_at
    }
  end

  def list_snapshots(user:)
    import_legacy_snapshots(user)
    Snapshot.where(user: user).order(created_at: :desc).map { |s| snapshot_json(s) }
  rescue Docker::Error::DockerError => e
    raise Error, "Failed to list snapshots: #{e.message}"
  end

  def find_snapshot(user:, name:)
    import_legacy_snapshots(user)
    Snapshot.find_by!(user: user, name: name)
  rescue ActiveRecord::RecordNotFound
    raise Error, "Snapshot '#{name}' not found"
  end

  def destroy_snapshot(user:, name:)
    snap = Snapshot.find_by(user: user, name: name)

    if snap
      # Remove Docker image
      if snap.docker_image.present?
        begin
          Docker::Image.get(snap.docker_image).remove
        rescue Docker::Error::NotFoundError
          # Already gone
        rescue Docker::Error::DockerError => e
          raise Error, "Failed to remove Docker image: #{e.message}"
        end
      end

      # Remove BTRFS snapshots
      if snap.home_snapshot.present?
        begin
          BtrfsHelper.delete_snapshot(snap.home_snapshot)
        rescue BtrfsHelper::Error => e
          Rails.logger.warn("Could not delete home snapshot #{snap.home_snapshot}: #{e.message}")
        end
      end

      if snap.data_snapshot.present?
        begin
          BtrfsHelper.delete_snapshot(snap.data_snapshot)
        rescue BtrfsHelper::Error => e
          Rails.logger.warn("Could not delete data snapshot #{snap.data_snapshot}: #{e.message}")
        end
      end

      snap.destroy!
    else
      # Legacy: try to find and remove Docker image directly
      image_ref = "sc-snap-#{user.name}:#{name}"
      begin
        Docker::Image.get(image_ref).remove
      rescue Docker::Error::NotFoundError
        raise Error, "Snapshot '#{name}' not found"
      rescue Docker::Error::DockerError => e
        raise Error, "Failed to destroy snapshot: #{e.message}"
      end
    end
  end

  def restore(sandbox:, snapshot_name:, layers: nil)
    user = sandbox.user
    was_tailscale = sandbox.tailscale?

    snap = Snapshot.find_by(user: user, name: snapshot_name)
    requested_layers = layers&.map(&:to_s)

    # Determine the Docker image to use
    if snap&.docker_image.present?
      image_ref = snap.docker_image
    else
      # Fall back to legacy naming
      image_ref = "sc-snap-#{user.name}:#{snapshot_name}"
    end

    restore_container = requested_layers.nil? || requested_layers.include?("container")
    restore_home      = snap&.home_snapshot.present? && (requested_layers.nil? || requested_layers.include?("home"))
    restore_data      = snap&.data_snapshot.present? && (requested_layers.nil? || requested_layers.include?("data"))

    # Validate the Docker image exists if we need it
    if restore_container
      begin
        Docker::Image.get(image_ref)
      rescue Docker::Error::NotFoundError
        raise Error, "Snapshot '#{snapshot_name}' not found"
      end
    end

    begin
      TerminalManager.new.close(sandbox: sandbox)
    rescue TerminalManager::Error, Docker::Error::DockerError
      # best-effort terminal cleanup
    end

    begin
      VncManager.new.close(sandbox: sandbox)
    rescue VncManager::Error, Docker::Error::DockerError
      # best-effort VNC cleanup
    end

    if sandbox.tailscale?
      TailscaleManager.new.disconnect_sandbox(sandbox: sandbox)
    end

    if sandbox.container_id.present?
      begin
        old_container = Docker::Container.get(sandbox.container_id)
        old_container.stop(t: 5) rescue nil
        old_container.delete(force: true)
      rescue Docker::Error::NotFoundError
        # Already gone
      end
    end

    # ── Restore home directory ────────────────────────────────────────────────
    if restore_home
      home_target = "#{DATA_DIR}/users/#{user.name}/home"
      begin
        BtrfsHelper.restore_subvolume(snap.home_snapshot, home_target)
      rescue BtrfsHelper::Error => e
        Rails.logger.warn("Could not restore home snapshot: #{e.message}")
      end
    end

    # ── Restore data directory ────────────────────────────────────────────────
    if restore_data
      if snap.data_subdir.present?
        data_target = "#{DATA_DIR}/users/#{user.name}/data/#{sandbox.data_path}/#{snap.data_subdir}".chomp("/")
      else
        data_target = "#{DATA_DIR}/users/#{user.name}/data/#{sandbox.data_path}".chomp("/")
      end
      begin
        BtrfsHelper.restore_subvolume(snap.data_snapshot, data_target)
      rescue BtrfsHelper::Error => e
        Rails.logger.warn("Could not restore data snapshot: #{e.message}")
      end
    end

    # ── Recreate container ────────────────────────────────────────────────────
    final_image = restore_container ? image_ref : sandbox.image

    container = Docker::Container.create(
      "name" => sandbox.full_name,
      "Image" => final_image,
      "Hostname" => sandbox.full_name,
      "Env" => container_env(user, sandbox),
      "Labels" => { "sandcastle.sandbox" => "true" },
      "HostConfig" => {
        "Runtime" => container_runtime,
        "NetworkMode" => NETWORK_NAME,
        "Binds" => volume_binds(user, sandbox),
        "RestartPolicy" => { "Name" => "unless-stopped" }
      },
      "NetworkingConfig" => {
        "EndpointsConfig" => { NETWORK_NAME => {} }
      }
    )

    container.start
    sandbox.update!(container_id: container.id, image: final_image, status: "running")

    # Connect to per-user network for tenant isolation
    NetworkManager.new.connect_sandbox(sandbox: sandbox)

    # Pre-write Traefik routes so they're active immediately after restore.
    TerminalManager.new.prepare_traefik_config(sandbox)
    VncManager.new.prepare_traefik_config(sandbox) if sandbox.vnc_enabled?

    if was_tailscale && user.tailscale_enabled?
      TailscaleManager.new.connect_sandbox(sandbox: sandbox)
    end

    sandbox
  rescue Docker::Error::DockerError => e
    raise Error, "Failed to restore snapshot: #{e.message}"
  end

  # Import legacy Docker-only snapshots as DB records (idempotent).
  def import_legacy_snapshots(user)
    repo_prefix = "sc-snap-#{user.name}"

    Docker::Image.all.each do |img|
      repo_tags = img.info["RepoTags"] || []
      repo_tags.each do |tag|
        repo, tag_name = tag.split(":")
        next unless repo == repo_prefix
        next if tag_name.blank?
        next if Snapshot.exists?(user: user, name: tag_name)

        Snapshot.create!(
          user: user,
          name: tag_name,
          docker_image: tag,
          docker_size: img.info["Size"],
          source_sandbox: img.info.dig("Comment")&.delete_prefix("sandbox:"),
          created_at: Time.at(img.info["Created"] || Time.current.to_i)
        )
      end
    end
  rescue Docker::Error::DockerError, ActiveRecord::RecordInvalid => e
    Rails.logger.warn("Legacy snapshot import failed: #{e.message}")
  end

  def snapshot_json(snap)
    {
      name: snap.name,
      label: snap.label,
      source_sandbox: snap.source_sandbox,
      layers: snap.layers,
      docker_image: snap.docker_image,
      docker_size: snap.docker_size,
      home_size: snap.home_size,
      data_size: snap.data_size,
      total_size: snap.total_size,
      created_at: snap.created_at
    }
  end

  def connect_info(sandbox:)
    user = sandbox.user.name

    unless sandbox.tailscale?
      raise Error, "SSH access requires Tailscale. Enable Tailscale on your account and connect this sandbox to your tailnet."
    end

    ts_ip = wait_for_tailscale_ip(sandbox: sandbox)
    raise Error, "Tailscale IP not available — is the Tailscale sidecar running?" unless ts_ip.present?

    {
      host: ts_ip,
      port: 22,
      user: user,
      command: "ssh #{user}@#{ts_ip}",
      tailscale_ip: ts_ip
    }
  end

  # Update the SMB password on all active SMB-enabled sandboxes for a user.
  def update_smb_password(user:)
    raise Error, "No SMB password set" unless user.smb_password.present?

    user.sandboxes.active.where(smb_enabled: true).find_each do |sandbox|
      next if sandbox.container_id.blank?

      begin
        container = Docker::Container.get(sandbox.container_id)
        set_smb_password(container, user)
      rescue Docker::Error::NotFoundError
        # Container gone, skip
      rescue Docker::Error::DockerError => e
        Rails.logger.warn("Failed to update SMB password for #{sandbox.full_name}: #{e.message}")
      end
    end
  end

  private

  def wait_for_tailscale_ip(sandbox:, max_attempts: 30, delay: 0.5)
    # Wait for the sandbox to be provisioned (background job) and Tailscale IP to be assigned
    max_attempts.times do
      sandbox.reload # Refresh from DB to get latest status

      # If sandbox isn't running yet, keep waiting (provision job in progress)
      if sandbox.status != "running"
        sleep delay
        next
      end

      # Sandbox is running, try to get Tailscale IP
      ts_ip = TailscaleManager.new.sandbox_tailscale_ip(sandbox: sandbox)
      return ts_ip if ts_ip.present?

      sleep delay
    end
    Rails.logger.warn("Tailscale IP not available for sandbox #{sandbox.id} after #{max_attempts} attempts (status: #{sandbox.status})")
    nil
  end

  def connect_to_network(container)
    network = Docker::Network.get(NETWORK_NAME)
    network.connect(container.id)
  rescue Docker::Error::NotFoundError
    Rails.logger.warn("SandboxManager: network #{NETWORK_NAME} not found, skipping network connection")
  rescue Docker::Error::DockerError => e
    Rails.logger.warn("SandboxManager: failed to connect container to #{NETWORK_NAME}: #{e.message}")
  end

  def container_env(user, sandbox)
    env = [
      "SANDCASTLE_USER=#{user.name}",
      "SANDCASTLE_SSH_KEY=#{user.ssh_public_key}"
    ]
    env << "USER_EMAIL=#{user.email_address}" if user.email_address.present?
    env << "USER_FULLNAME=#{user.full_name}" if user.full_name.present?
    env << "GITHUB_USERNAME=#{user.github_username}" if user.github_username.present?
    env << "SANDCASTLE_VNC_ENABLED=#{sandbox.vnc_enabled? ? '1' : '0'}"
    env << "SANDCASTLE_VNC_GEOMETRY=#{sandbox.vnc_geometry}"
    env << "SANDCASTLE_VNC_DEPTH=#{sandbox.vnc_depth}"
    env << "SANDCASTLE_DOCKER_ENABLED=#{sandbox.docker_enabled? ? '1' : '0'}"
    env << "SANDCASTLE_SMB_ENABLED=#{sandbox.smb_enabled? ? '1' : '0'}"
    env << "SANDCASTLE_HOME_PERSISTED=#{sandbox.mount_home ? '1' : '0'}"
    env << "SANDCASTLE_DATA_PERSISTED=#{sandbox.data_path.present? ? '1' : '0'}"
    env << "SANDCASTLE_DATA_PATH=#{sandbox.data_path}" if sandbox.data_path.present?
    env
  end

  def container_runtime
    @container_runtime ||= begin
      runtimes = Docker.info["Runtimes"] || {}
      if runtimes.key?("sysbox-runc")
        "sysbox-runc"
      else
        Rails.logger.warn("SandboxManager: sysbox-runc not available, falling back to runc (Docker-in-Docker will not work inside sandboxes)")
        "runc"
      end
    end
  end

  # mkdir_p with self-healing: if EACCES, fix the parent dir's ownership
  # via a short-lived Docker container (only way when running as non-root
  # inside a container with Docker socket access).
  def ensure_dir(path)
    FileUtils.mkdir_p(path)
  rescue Errno::EACCES
    docker_chown(File.dirname(path))
    FileUtils.mkdir_p(path)
  end

  # Ensure a bind-mounted directory is world-writable so the sandbox user
  # (non-root inside the Sysbox container) can write to it.
  def prepare_bind_mount(path)
    stat = File.stat(path)
    return if stat.mode & 0o777 == 0o777
    return if system("/usr/bin/sudo", "-n", "/usr/bin/chmod", "777", path)
    docker_chmod(path, "777")
  rescue Errno::ENOENT
    # directory disappeared — race condition, ignore
  end

  # Fix ownership and permissions of a host path via a busybox container.
  def docker_chown(path)
    docker_run_fix(path, "sh", "-c", "chown #{Process.uid}:#{Process.gid} /mnt && chmod 755 /mnt")
  end

  def docker_chmod(path, mode)
    docker_run_fix(path, "chmod", mode, "/mnt")
  rescue Docker::Error::DockerError => e
    Rails.logger.warn("docker_chmod(#{path}) failed: #{e.message}")
  end

  def docker_run_fix(host_path, *cmd)
    image = fix_image
    c = Docker::Container.create(
      "Image" => image, "Cmd" => cmd,
      "HostConfig" => { "Binds" => [ "#{host_path}:/mnt" ] }
    )
    c.start
    result = c.wait(30)
    exit_code = result&.dig("StatusCode") || -1
    unless exit_code == 0
      raise Error, "docker_run_fix failed (exit #{exit_code}) for #{host_path}: #{cmd.join(' ')}"
    end
  ensure
    c&.delete(force: true) rescue nil
  end

  # Pick an image guaranteed to be on this Docker daemon.
  # Prefer busybox (tiny), fall back to alpine, then any local image.
  def fix_image
    %w[busybox:latest alpine:latest].each do |img|
      begin
        return img if Docker::Image.get(img)
      rescue Docker::Error::DockerError
        next
      end
    end
    # Last resort: use any image already present
    all = Docker::Image.all
    raise Error, "No local images available for docker_run_fix" if all.empty?
    tags = all.first.info["RepoTags"]
    tags&.first || all.first.id
  end

  # Inject SMB password into the container via exec, avoiding env var leakage.
  def set_smb_password(container, user)
    return unless user.smb_password.present?

    username = user.name
    password = user.smb_password
    container.exec(
      ["bash", "-c", "printf '%s\\n%s\\n' \"$0\" \"$0\" | smbpasswd -a -s \"$1\" 2>&1 || echo 'Warning: smbpasswd failed' >&2",
       password, username]
    )
  rescue Docker::Error::DockerError => e
    Rails.logger.warn("set_smb_password failed for #{user.name}: #{e.message}")
  end

  def volume_binds(user, sandbox)
    binds = []
    if sandbox.mount_home
      binds << "#{DATA_DIR}/users/#{user.name}/home:/home/#{user.name}"
    end
    if sandbox.data_path.present?
      host_path = "#{DATA_DIR}/users/#{user.name}/data/#{sandbox.data_path}".chomp("/")
      binds << "#{host_path}:/persisted"
    end
    # Chrome profile persistence: mount separately if not mounting full home
    if user.chrome_persist_profile? && !sandbox.mount_home
      host_path = "#{DATA_DIR}/users/#{user.name}/chrome-profile"
      binds << "#{host_path}:/home/#{user.name}/.config/google-chrome"
    end
    binds
  end
end
