class SandboxRebuildJob < ApplicationJob
  queue_as :default

  def perform(sandbox_id:)
    sandbox = Sandbox.find(sandbox_id)

    begin
      SandboxManager.new.rebuild(sandbox: sandbox)
      DnsManager.publish_best_effort(sandbox.user) if sandbox.user.tailscale_enabled?
      sandbox.finish_job
    rescue => e
      Rails.logger.error("SandboxRebuildJob failed: #{e.message}\n#{e.backtrace.join("\n")}")
      sandbox.fail_job("Failed to rebuild: #{e.message}")
      raise
    end
  end
end
