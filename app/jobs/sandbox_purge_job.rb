class SandboxPurgeJob < ApplicationJob
  queue_as :default

  def perform
    # Find all archived sandboxes. Group by user so we can apply per-user retention windows.
    Sandbox.where(status: "archived").includes(:user).find_each do |sandbox|
      next unless sandbox.archived_at.present?

      retention = sandbox.user.effective_archive_retention_days
      next if retention <= 0 # 0 means disable archiving (but sandbox was archived before setting changed)

      if sandbox.archived_at < retention.days.ago
        sandbox.with_lock do
          sandbox.reload
          next unless sandbox.status == "archived" && sandbox.archived_at.present?

          recomputed_retention = sandbox.user.effective_archive_retention_days
          next if recomputed_retention <= 0
          next unless sandbox.archived_at < recomputed_retention.days.ago

          Rails.logger.info("SandboxPurgeJob: purging #{sandbox.full_name} (archived #{sandbox.archived_at}, retention #{recomputed_retention}d)")
          SandboxManager.new.destroy(sandbox: sandbox, archive: false)
        end
      end
    rescue => e
      Rails.logger.error("SandboxPurgeJob: failed to purge sandbox #{sandbox.id}: #{e.message}")
    end
  end
end
