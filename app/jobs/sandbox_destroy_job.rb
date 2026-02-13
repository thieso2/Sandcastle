class SandboxDestroyJob < ApplicationJob
  queue_as :default

  def perform(sandbox_id:)
    sandbox = Sandbox.find(sandbox_id)
    return if sandbox.status == "destroyed" # Idempotent

    sandbox.start_job("destroying")

    begin
      SandboxManager.new.destroy(sandbox: sandbox)
      sandbox.finish_job

      # Broadcast success toast
      broadcast_toast(
        user_id: sandbox.user.id,
        message: "Sandbox #{sandbox.name} destroyed",
        level: "success"
      )

    rescue => e
      Rails.logger.error("SandboxDestroyJob failed: #{e.message}\n#{e.backtrace.join("\n")}")
      sandbox.fail_job("Failed to destroy: #{e.message}")

      # Broadcast failure toast
      broadcast_toast(
        user_id: sandbox.user.id,
        message: "Failed to destroy sandbox #{sandbox.name}: #{e.message}",
        level: "error"
      )

      raise
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
  end
end
