class SandboxDestroyJob < ApplicationJob
  queue_as :default

  def perform(sandbox_id:)
    Rails.logger.info "[SandboxDestroyJob] Starting for sandbox #{sandbox_id}"
    sandbox = Sandbox.find(sandbox_id)

    if sandbox.status == "destroyed"
      Rails.logger.info "[SandboxDestroyJob] Sandbox already destroyed, skipping"
      return
    end

    begin
      Rails.logger.info "[SandboxDestroyJob] Calling SandboxManager.destroy"
      SandboxManager.new.destroy(sandbox: sandbox)
      Rails.logger.info "[SandboxDestroyJob] Destroy successful, calling finish_job"
      sandbox.finish_job
      Rails.logger.info "[SandboxDestroyJob] Completed successfully"

    rescue => e
      Rails.logger.error("[SandboxDestroyJob] Failed: #{e.message}\n#{e.backtrace.join("\n")}")
      sandbox.fail_job("Failed to destroy: #{e.message}")

      raise
    end
  end
end
