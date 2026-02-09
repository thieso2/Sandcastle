class ContainerSyncJob < ApplicationJob
  queue_as :default

  def perform
    Sandbox.active.where.not(container_id: nil).find_each do |sandbox|
      sync_sandbox(sandbox)
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
end
