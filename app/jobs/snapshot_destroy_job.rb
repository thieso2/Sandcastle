class SnapshotDestroyJob < ApplicationJob
  queue_as :default

  def perform(user_id:, snapshot_name:)
    user = User.find(user_id)
    SandboxManager.new.destroy_snapshot(user: user, name: snapshot_name)
  rescue => e
    Rails.logger.error("SnapshotDestroyJob failed: #{e.message}\n#{e.backtrace.join("\n")}")
    raise
  end
end
