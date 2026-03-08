# Orchestrates a self-update: pulls fresh images from GHCR, then spawns a
# short-lived "updater" container that runs `docker compose up -d` from outside
# the web container — necessary because the web container cannot recreate itself
# while it is still running.
class UpdateManager
  APP_IMAGE    = "ghcr.io/thieso2/sandcastle:latest"
  SANDBOX_IMAGE = SandboxManager::DEFAULT_IMAGE
  COMPOSE_PATH  = "/sandcastle/docker-compose.yml"

  class Error < StandardError; end

  # Pulls images (app + sandbox by default) and spawns the updater container.
  # The caller's HTTP response will complete before the compose restart kicks in
  # (the updater sleeps 2 s before running compose).
  def perform_update!(pull_app: true, pull_sandbox: true)
    pull_image(APP_IMAGE)     if pull_app
    pull_image(SANDBOX_IMAGE) if pull_sandbox
    spawn_updater_container
  rescue Error
    raise
  rescue Docker::Error::DockerError => e
    raise Error, "Docker error during update: #{e.message}"
  end

  private

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
  rescue Docker::Error::DockerError => e
    raise Error, "Failed to spawn updater container: #{e.message}"
  end
end
