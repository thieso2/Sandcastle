class SandboxProvisionJob < ApplicationJob
  queue_as :default

  def perform(user_id:, name:, image: SandboxManager::DEFAULT_IMAGE, persistent: false)
    user = User.find(user_id)
    SandboxManager.new.create(user: user, name: name, image: image, persistent: persistent)
  rescue SandboxManager::Error => e
    Rails.logger.error("SandboxProvisionJob failed: #{e.message}")
    raise
  end
end
