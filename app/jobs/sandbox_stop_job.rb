class SandboxStopJob < ApplicationJob
  queue_as :default

  def perform(sandbox_id:)
    sandbox = Sandbox.find(sandbox_id)
    return if sandbox.status == "stopped" # Idempotent

    begin
      SandboxManager.new.stop(sandbox: sandbox)
      sandbox.finish_job

    rescue => e
      Rails.logger.error("SandboxStopJob failed: #{e.message}\n#{e.backtrace.join("\n")}")
      sandbox.fail_job("Failed to stop: #{e.message}")

      raise
    end
  end
end
