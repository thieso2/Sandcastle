class SandboxDestroyJob < ApplicationJob
  queue_as :default

  def perform(sandbox_id:, archive: false)
    sandbox = Sandbox.find(sandbox_id)
    return if sandbox.status.in?(%w[destroyed archived]) # Idempotent

    begin
      SandboxManager.new.destroy(sandbox: sandbox, archive: archive)
      sandbox.finish_job

    rescue => e
      Rails.logger.error("SandboxDestroyJob failed: #{e.message}\n#{e.backtrace.join("\n")}")
      sandbox.fail_job("Failed to destroy: #{e.message}")

      raise
    end
  end
end
