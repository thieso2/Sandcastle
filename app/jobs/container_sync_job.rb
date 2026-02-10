class ContainerSyncJob < ApplicationJob
  queue_as :default

  def perform
    Sandbox.active.where.not(container_id: nil).find_each do |sandbox|
      sync_sandbox(sandbox)
    end

    User.where(tailscale_state: [ "enabled", "pending" ]).find_each do |user|
      sync_tailscale_sidecar(user)
    end

    begin
      RouteManager.new.sync_all_configs
    rescue => e
      Rails.logger.error("ContainerSyncJob: route sync failed: #{e.message}")
    end
  end

  private

  def sync_sandbox(sandbox)
    container = Docker::Container.get(sandbox.container_id)
    actual_status = container.json.dig("State", "Running") ? "running" : "stopped"

    if sandbox.status != actual_status
      sandbox.update!(status: actual_status)
      Rails.logger.info("ContainerSyncJob: #{sandbox.full_name} status corrected to #{actual_status}")
    end
  rescue Docker::Error::NotFoundError
    sandbox.update!(status: "destroyed", container_id: nil)
    Rails.logger.warn("ContainerSyncJob: #{sandbox.full_name} container gone, marked destroyed")
  end

  def sync_tailscale_sidecar(user)
    return if user.tailscale_container_id.blank?

    Docker::Container.get(user.tailscale_container_id)
  rescue Docker::Error::NotFoundError
    user.update!(tailscale_state: "disabled", tailscale_container_id: nil, tailscale_network: nil)
    user.sandboxes.active.where(tailscale: true).update_all(tailscale: false)
    Rails.logger.warn("ContainerSyncJob: Tailscale sidecar for #{user.name} gone, marked disabled")
  end
end
