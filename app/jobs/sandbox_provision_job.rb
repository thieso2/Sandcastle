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

      # Broadcast success toast
      broadcast_toast(
        user_id: sandbox.user.id,
        message: "Sandbox #{sandbox.name} created successfully!",
        level: "success"
      )

    rescue => e
      Rails.logger.error("SandboxProvisionJob failed: #{e.message}\n#{e.backtrace.join("\n")}")
      sandbox.fail_job("Failed to create: #{e.message}")
      sandbox.update!(status: "destroyed")

      # Broadcast failure toast
      broadcast_toast(
        user_id: sandbox.user.id,
        message: "Failed to create sandbox #{sandbox.name}: #{e.message}",
        level: "error"
      )

      raise # Re-raise for Solid Queue retry
    end
  end

  private

  def broadcast_toast(user_id:, message:, level:)
    Turbo::StreamsChannel.broadcast_append_to(
      "user_#{user_id}",
      target: "toasts",
      partial: "shared/toast",
      locals: {
        message: message,
        level: level,
        dom_id: "toast_#{SecureRandom.hex(8)}"
      }
    )
  rescue => e
    Rails.logger.error("Failed to broadcast toast: #{e.message}")
    # Don't raise - toast failure shouldn't break the job
  end
  end
end
