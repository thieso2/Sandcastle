class ContainerSyncJob < ApplicationJob
  queue_as :default

  def perform
    Sandbox.active.where.not(container_id: nil).find_each do |sandbox|
      sync_sandbox(sandbox)
    end

    User.where(tailscale_state: [ "enabled", "pending" ]).find_each do |user|
      sync_tailscale_sidecar(user)
    end

    User.where(tailscale_state: "disabled").find_each do |user|
      restore_tailscale_from_saved_key(user)
    end

    # Reconcile per-user network membership for running sandboxes
    sync_user_networks

    begin
      RouteManager.new.sync_all_configs
    rescue => e
      Rails.logger.error("ContainerSyncJob: route sync failed: #{e.message}")
    end

    begin
      TerminalManager.new.cleanup_orphaned
    rescue => e
      Rails.logger.error("ContainerSyncJob: terminal cleanup failed: #{e.message}")
    end

    begin
      VncManager.new.cleanup_orphaned
    rescue => e
      Rails.logger.error("ContainerSyncJob: VNC cleanup failed: #{e.message}")
    end
  end

  private

  def sync_sandbox(sandbox)
    container = Docker::Container.get(sandbox.container_id)
    state = container.json["State"] || {}
    actual_status = if state["Restarting"]
      "stopped"
    elsif state["Running"]
      "running"
    else
      "stopped"
    end

    if sandbox.status != actual_status
      if actual_status == "stopped"
        begin
          TerminalManager.new.close(sandbox: sandbox)
        rescue TerminalManager::Error, Docker::Error::DockerError
          # best-effort
        end
        begin
          VncManager.new.close(sandbox: sandbox)
        rescue VncManager::Error, Docker::Error::DockerError
          # best-effort
        end
      end
      sandbox.update!(status: actual_status)
      Rails.logger.info("ContainerSyncJob: #{sandbox.full_name} status corrected to #{actual_status}")
    end
  rescue Docker::Error::NotFoundError
    begin
      TerminalManager.new.close(sandbox: sandbox)
    rescue TerminalManager::Error, Docker::Error::DockerError
      # best-effort
    end
    begin
      VncManager.new.close(sandbox: sandbox)
    rescue VncManager::Error, Docker::Error::DockerError
      # best-effort
    end
    sandbox.update!(status: "destroyed", container_id: nil)
    Rails.logger.warn("ContainerSyncJob: #{sandbox.full_name} container gone, marked destroyed")
  end

  def restore_tailscale_from_saved_key(user)
    tm = TailscaleManager.new
    auth_key = File.read(tm.auth_key_path(user)).strip rescue nil
    if auth_key.present?
      tm.enable(user: user, auth_key: auth_key)
      Rails.logger.info("ContainerSyncJob: restored Tailscale for #{user.name} from saved auth key")
      return
    end

    # Fallback: restore from persisted tailscaled.state (interactive-login survivors).
    # We check if the tailscale *directory* exists (readable via parent dir's 755 perms)
    # rather than the state file inside it (which is in a root-owned drwx------ dir).
    state_dir = File.join(TailscaleManager::DATA_DIR, "users", user.name, "tailscale")
    return unless File.directory?(state_dir)

    tm.restore_from_state(user: user)
    Rails.logger.info("ContainerSyncJob: restored Tailscale for #{user.name} from saved state")
  rescue TailscaleManager::Error => e
    Rails.logger.warn("ContainerSyncJob: Tailscale restore for #{user.name} failed: #{e.message}")
  rescue => e
    Rails.logger.error("ContainerSyncJob: Tailscale restore for #{user.name} unexpected error: #{e.message}")
  end

  def sync_user_networks
    nm = NetworkManager.new

    # Ensure all running sandboxes are connected to their user's per-user network
    Sandbox.running.where.not(container_id: nil).find_each do |sandbox|
      nm.ensure_sandbox_connected(sandbox: sandbox)
    rescue => e
      Rails.logger.error("ContainerSyncJob: user network sync failed for #{sandbox.full_name}: #{e.message}")
    end

    # Clean up orphaned user networks (user has no active sandboxes)
    User.where.not(network_name: nil).find_each do |user|
      nm.cleanup_user_network(user) unless user.sandboxes.active.exists?
    rescue => e
      Rails.logger.error("ContainerSyncJob: user network cleanup failed for #{user.name}: #{e.message}")
    end
  rescue => e
    Rails.logger.error("ContainerSyncJob: sync_user_networks failed: #{e.message}")
  end

  def sync_tailscale_sidecar(user)
    return if user.tailscale_container_id.blank?

    Docker::Container.get(user.tailscale_container_id)
  rescue Docker::Error::NotFoundError
    was_enabled = user.tailscale_enabled?
    user.update!(tailscale_state: "disabled", tailscale_container_id: nil, tailscale_network: nil)
    user.sandboxes.active.where(tailscale: true).update_all(tailscale: false)
    Rails.logger.warn("ContainerSyncJob: Tailscale sidecar for #{user.name} gone, marked disabled")

    # If user had a live sidecar (not just pending login), try to restore from
    # persisted tailscaled.state so they reconnect automatically after reinstall.
    # The tailscale dir is root-owned so we can't check File.exist? — just attempt it.
    return unless was_enabled

    begin
      TailscaleManager.new.restore_from_state(user: user.reload)
      Rails.logger.info("ContainerSyncJob: Tailscale sidecar for #{user.name} restored from saved state")
    rescue TailscaleManager::Error => e
      Rails.logger.warn("ContainerSyncJob: Tailscale state restore for #{user.name} failed: #{e.message}")
    rescue => e
      Rails.logger.error("ContainerSyncJob: Tailscale state restore for #{user.name} unexpected error: #{e.message}")
    end
  end
end
