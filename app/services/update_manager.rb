# Orchestrates a self-update: pulls fresh images from GHCR, then spawns a
# short-lived "updater" container that runs `docker compose up -d` from outside
# the web container — necessary because the web container cannot recreate itself
# while it is still running.
#
# Update flow:
#   1. POST /admin/update/pull?target=X   → starts background pull, tracks via cache
#   2. GET  /admin/update/status           → polls pull progress
#   3. POST /admin/update/restart          → spawns updater container
#   4. GET  /admin/update/progress         → fullscreen page that polls until app is back
class UpdateManager
  APP_IMAGE     = "ghcr.io/thieso2/sandcastle:latest"
  SANDBOX_IMAGE = SandboxManager::DEFAULT_IMAGE
  COMPOSE_PATH  = "/sandcastle/docker-compose.yml"
  CACHE_KEY     = "update_manager/pull_status"

  class Error < StandardError; end

  # Starts pulling images in a background thread. Progress is tracked in cache.
  def start_pull(target:)
    pull_app     = %w[all app].include?(target)
    pull_sandbox = %w[all sandbox].include?(target)

    write_status(state: "pulling", target: target, started_at: Time.current.iso8601)

    Thread.new do
      begin
        if pull_app
          write_status(state: "pulling", target: target, step: "Pulling app image…")
          pull_image(APP_IMAGE)
        end

        if pull_sandbox
          write_status(state: "pulling", target: target, step: "Pulling sandbox image…")
          pull_image(SANDBOX_IMAGE)
        end

        write_status(state: "ready", target: target, step: "Images pulled. Ready to apply.")
      rescue => e
        write_status(state: "error", target: target, step: e.message)
      end
    end
  end

  # Returns the current pull status hash from cache.
  def pull_status
    Rails.cache.read(CACHE_KEY) || { state: "idle" }
  end

  # Spawns the updater container that restarts the app via docker compose.
  def restart!
    spawn_updater_container
    Rails.cache.delete(CACHE_KEY)
    Rails.cache.delete(UpdateChecker::CACHE_KEY)
  rescue Docker::Error::DockerError => e
    raise Error, "Failed to spawn updater container: #{e.message}"
  end

  private

  def write_status(hash)
    Rails.cache.write(CACHE_KEY, hash, expires_in: 10.minutes)
  end

  def pull_image(image)
    Docker::Image.create("fromImage" => image)
  rescue Docker::Error::DockerError => e
    raise Error, "Failed to pull #{image}: #{e.message}"
  end

  def spawn_updater_container
    container = Docker::Container.create(
      "Image" => APP_IMAGE,
      "Cmd"   => [ "sh", "-c",
                   "sleep 2 && docker compose -f #{COMPOSE_PATH} up -d" ],
      "HostConfig" => {
        "Binds" => [
          "/var/run/docker.sock:/var/run/docker.sock",
          "/sandcastle:/sandcastle"
        ],
        "AutoRemove" => true
      }
    )
    container.start
  end
end
