class SandboxCaddyReloadJob < ApplicationJob
  queue_as :default

  def perform(sandbox_id)
    sandbox = Sandbox.find_by(id: sandbox_id)
    return unless sandbox

    SandboxCaddyManager.new.reconfigure(sandbox)
  rescue SandboxCaddyManager::Error => e
    Rails.logger.warn("SandboxCaddyReloadJob: #{e.message}")
  end
end
