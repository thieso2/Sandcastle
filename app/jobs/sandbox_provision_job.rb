class SandboxProvisionJob < ApplicationJob
  queue_as :default

  def perform(sandbox_id:)
    sandbox = Sandbox.find(sandbox_id)
    return if sandbox.status == "running" # Idempotent

    sandbox.start_job("creating")
    manager = SandboxManager.new

    begin
      # Directory creation
      manager.ensure_mount_dirs(sandbox.user, sandbox)

      # Image pull (can be slow)
      manager.ensure_image(sandbox.image)

      # Container creation and start
      manager.create_container_and_start(sandbox: sandbox, user: sandbox.user)

      # Connect to Tailscale if enabled
      if sandbox.tailscale? && sandbox.user.tailscale_enabled?
        TailscaleManager.new.connect_sandbox(sandbox: sandbox)
      end

      sandbox.update!(status: "running")
      sandbox.finish_job

    rescue => e
      Rails.logger.error("SandboxProvisionJob failed: #{e.message}\n#{e.backtrace.join("\n")}")
      sandbox.fail_job("Failed to create: #{e.message}")
      sandbox.update!(status: "destroyed")

      raise # Re-raise for Solid Queue retry
    end
  end
end
