class TailscaleLoginJob < ApplicationJob
  queue_as :default

  def perform(user_id:)
    user = User.find(user_id)
    return unless user.tailscale_pending?
    return if user.tailscale_container_id.present?

    TailscaleManager.new.start_login(user: user)
  rescue TailscaleManager::Error, Docker::Error::DockerError => e
    Rails.logger.error("TailscaleLoginJob failed for user #{user_id}: #{e.message}")
    user.update!(tailscale_state: "disabled", tailscale_container_id: nil, tailscale_network: nil)
    Rails.cache.write("ts_login_error:#{user_id}", e.message, expires_in: 5.minutes)
  end
end
