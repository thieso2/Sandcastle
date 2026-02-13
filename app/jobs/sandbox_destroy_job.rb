class SandboxDestroyJob < ApplicationJob
  queue_as :default

  def perform(sandbox_id:)
    sandbox = Sandbox.find(sandbox_id)
    return if sandbox.status == "destroyed" # Idempotent

    sandbox.start_job("destroying")

    begin
      SandboxManager.new.destroy(sandbox: sandbox)
      sandbox.finish_job
    rescue => e
      Rails.logger.error("SandboxDestroyJob failed: #{e.message}\n#{e.backtrace.join("\n")}")
      sandbox.fail_job("Failed to destroy: #{e.message}")
      raise
    end
  end
end
