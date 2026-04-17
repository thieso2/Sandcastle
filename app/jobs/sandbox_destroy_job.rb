class SandboxDestroyJob < ApplicationJob
  queue_as :default

  def perform(sandbox_id:, archive: false)
    sandbox = Sandbox.find_by(id: sandbox_id)
    return unless sandbox

    # Idempotent exits: a destroyed sandbox never needs further work, and an
    # already-archived sandbox doesn't need to be re-archived. Purging an
    # archived sandbox (archive: false) must still proceed — that's the
    # "Really delete" flow. Clear job_status on exit so the controller's
    # job_in_progress? guard doesn't stick.
    if sandbox.status == "destroyed" || (archive && sandbox.status == "archived")
      sandbox.finish_job
      return
    end

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
