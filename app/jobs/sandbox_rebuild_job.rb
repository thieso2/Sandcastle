class SandboxRebuildJob < ApplicationJob
  queue_as :default

  def perform(sandbox_id:)
    sandbox = Sandbox.find(sandbox_id)

    begin
      SandboxManager.new.rebuild(sandbox: sandbox)
      sandbox.finish_job
    rescue => e
      Rails.logger.error("SandboxRebuildJob failed: #{e.message}\n#{e.backtrace.join("\n")}")
      sandbox.fail_job("Failed to rebuild: #{e.message}")
      raise
    end
  end
end
