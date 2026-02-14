# Verify all sandboxes against Docker on app startup
# Ensures database state matches actual container state
Rails.application.config.after_initialize do
  # Only run in production/development, skip in test environment
  unless Rails.env.test?
    begin
      # Run container sync to verify all sandboxes
      # This will mark any missing containers as destroyed
      ContainerSyncJob.perform_now
      Rails.logger.info("Startup: container sync completed")
    rescue => e
      Rails.logger.warn("Startup: container sync failed: #{e.message}")
    end
  end
end
