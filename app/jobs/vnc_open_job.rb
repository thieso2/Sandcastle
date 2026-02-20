class VncOpenJob < ApplicationJob
  queue_as :default

  def perform(sandbox_id:)
    sandbox = Sandbox.find(sandbox_id)
    return unless sandbox.status == "running"

    sandbox.start_job("opening_vnc")

    begin
      VncManager.new.open(sandbox: sandbox)
      sandbox.finish_job
    rescue => e
      Rails.logger.error("VncOpenJob failed: #{e.message}\n#{e.backtrace.join("\n")}")
      sandbox.fail_job("Failed to open browser: #{e.message}")
      # Don't re-raise - VNC failures shouldn't retry
    end
  end
end
