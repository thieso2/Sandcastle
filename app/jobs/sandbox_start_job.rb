class SandboxStartJob < ApplicationJob
  queue_as :default

  def perform(sandbox_id:)
    sandbox = Sandbox.find(sandbox_id)
    return if sandbox.status == "running" # Idempotent

    begin
      SandboxManager.new.start(sandbox: sandbox)
      DnsManager.publish_best_effort(sandbox.user) if sandbox.user.tailscale_enabled?
      sandbox.finish_job
    rescue => e
      Rails.logger.error("SandboxStartJob failed: #{e.message}\n#{e.backtrace.join("\n")}")
      sandbox.fail_job("Failed to start: #{e.message}")
      raise
    end
  end
end
