class SandboxStartJob < ApplicationJob
  queue_as :default

  def perform(sandbox_id:)
    sandbox = Sandbox.find(sandbox_id)
    return if sandbox.status == "running" # Idempotent

    sandbox.start_job("starting")

    begin
      SandboxManager.new.start(sandbox: sandbox)
      sandbox.finish_job
    rescue => e
      Rails.logger.error("SandboxStartJob failed: #{e.message}\n#{e.backtrace.join("\n")}")
      sandbox.fail_job("Failed to start: #{e.message}")
      raise
    end
  end
end
