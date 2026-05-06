class SandboxRestoreJob < ApplicationJob
  queue_as :default

  def perform(sandbox_id:)
    sandbox = Sandbox.find_by(id: sandbox_id)
    return unless sandbox
    return unless sandbox.status == "archived" # Idempotent

    begin
      SandboxManager.new.restore_from_archive(sandbox: sandbox)
      DnsManager.publish_best_effort(sandbox.user) if sandbox.user.tailscale_enabled?
      sandbox.finish_job
    rescue => e
      Rails.logger.error("SandboxRestoreJob failed: #{e.message}\n#{e.backtrace.join("\n")}")
      sandbox.fail_job("Failed to restore: #{e.message}")
      raise
    end
  end
end
