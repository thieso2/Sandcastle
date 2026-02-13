class TerminalOpenJob < ApplicationJob
  queue_as :default

  def perform(sandbox_id:)
    sandbox = Sandbox.find(sandbox_id)
    return unless sandbox.status == "running"

    sandbox.start_job("opening_terminal")

    begin
      TerminalManager.new.open(sandbox: sandbox)
      sandbox.finish_job
    rescue => e
      Rails.logger.error("TerminalOpenJob failed: #{e.message}\n#{e.backtrace.join("\n")}")
      sandbox.fail_job("Failed to open terminal: #{e.message}")
      # Don't re-raise - terminal failures shouldn't retry
    end
  end
end
