class ContainerSyncJob < ApplicationJob
  queue_as :default

  def perform
    Sandbox.active.where.not(container_id: nil).find_each do |sandbox|
      sync_sandbox(sandbox)
    end
  end

  private

  def sync_sandbox(sandbox)
    state = incus.get_instance_state(sandbox.container_id)
    actual_status = state["status"] == "Running" ? "running" : "stopped"

    if sandbox.status != actual_status
      sandbox.update!(status: actual_status)
      Rails.logger.info("ContainerSyncJob: #{sandbox.full_name} status corrected to #{actual_status}")
    end
  rescue IncusClient::NotFoundError
    sandbox.update!(status: "destroyed", container_id: nil)
    Rails.logger.warn("ContainerSyncJob: #{sandbox.full_name} instance gone, marked destroyed")
  end

  def incus
    @incus ||= IncusClient.new
  end
end
