# Verify all sandboxes against Docker on app startup
# Ensures database state matches actual container state
Rails.application.config.after_initialize do
  # Only run in production/development, skip in test environment
  # Skip if Docker socket is not available (e.g. migrate container)
  unless Rails.env.test? || !File.exist?("/var/run/docker.sock")
    begin
      # Run container sync to verify all sandboxes
      # This will mark any missing containers as destroyed
      ContainerSyncJob.perform_now
      Rails.logger.info("Startup: container sync completed")
    rescue => e
      Rails.logger.warn("Startup: container sync failed: #{e.message}")
    end

    # Restore Traefik terminal/VNC configs for all running sandboxes.
    # These are cleaned up when sandboxes stop (cleanup_orphaned), so they
    # must be re-written after a Rails restart to keep terminal/VNC routing live.
    begin
      tm = TerminalManager.new
      vm = VncManager.new
      Sandbox.running.find_each do |sandbox|
        tm.prepare_traefik_config(sandbox)
        vm.prepare_traefik_config(sandbox) if sandbox.vnc_enabled?
      end
      Rails.logger.info("Startup: Traefik terminal/VNC configs restored")
    rescue => e
      Rails.logger.warn("Startup: Traefik config restore failed: #{e.message}")
    end
  end
end
