class StuckJobCleanupJob < ApplicationJob
  queue_as :default

  def perform
    Sandbox.where.not(job_status: nil)
           .where("job_started_at < ?", 5.minutes.ago)
           .find_each do |sandbox|
      Rails.logger.error("Stuck job detected: sandbox=#{sandbox.id} job_status=#{sandbox.job_status}")
      sandbox.fail_job("Job timed out after 5 minutes")
    end
  end
end
