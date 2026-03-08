require "net/http"
require "json"

# Checks whether newer versions of the Sandcastle app and sandbox images are
# available in GHCR. Results are cached for 15 minutes to avoid hammering the
# registry API on every admin page load.
class UpdateChecker
  GHCR_HOST  = "ghcr.io"
  OWNER      = "thieso2"
  APP_REPO   = "sandcastle"
  BOX_REPO   = "sandcastle-sandbox"
  CACHE_KEY  = "update_checker/status"
  CACHE_TTL  = 15.minutes

  class Error < StandardError; end

  # Returns cached (or fresh) update status hash.
  def check
    Rails.cache.fetch(CACHE_KEY, expires_in: CACHE_TTL) { perform_check }
  end

  # Busts the cache and re-checks immediately.
  def force_check
    Rails.cache.delete(CACHE_KEY)
    check
  end

  private

  def perform_check
    app_token     = fetch_anonymous_token(APP_REPO)
    sandbox_token = fetch_anonymous_token(BOX_REPO)

    {
      app:              image_status(APP_REPO, "ghcr.io/#{OWNER}/#{APP_REPO}:latest", app_token),
      sandbox:          image_status(BOX_REPO, "ghcr.io/#{OWNER}/#{BOX_REPO}:latest", sandbox_token),
      restart_pending:  restart_pending?,
      checked_at:       Time.current
    }
  rescue => e
    Rails.logger.error("UpdateChecker#perform_check failed: #{e.message}")
    { error: e.message, checked_at: Time.current }
  end

  def image_status(repo, local_ref, token)
    local_digest   = local_repo_digest(local_ref)
    remote_digest  = remote_manifest_digest(repo, token)
    local_version  = local_image_version(local_ref)
    remote_version = latest_remote_tag(repo, token)

    {
      local_digest:     local_digest,
      remote_digest:    remote_digest,
      local_version:    local_version,
      remote_version:   remote_version,
      update_available: local_digest.present? && remote_digest.present? && local_digest != remote_digest
    }
  rescue => e
    Rails.logger.warn("UpdateChecker#image_status(#{repo}) failed: #{e.message}")
    { error: e.message }
  end

  # Checks if the pulled app image is newer than the running container's image.
  def restart_pending?
    container = Docker::Container.get("sandcastle-web")
    running_image_id = container.info["Image"] || container.json["Image"]

    latest_image = Docker::Image.get("ghcr.io/#{OWNER}/#{APP_REPO}:latest")
    latest_image_id = latest_image.id

    running_image_id.present? && latest_image_id.present? && running_image_id != latest_image_id
  rescue Docker::Error::DockerError
    false
  end

  # Returns the manifest digest stored in the image's RepoDigests (e.g.
  # "sha256:abc123") — the digest it had when pulled from the registry.
  def local_repo_digest(image_ref)
    img = Docker::Image.get(image_ref)
    digests = img.info["RepoDigests"] || []
    digests.first&.split("@")&.last
  rescue Docker::Error::NotFoundError, Docker::Error::DockerError
    nil
  end

  # Extracts the version from a local image's labels or env vars.
  def local_image_version(image_ref)
    img    = Docker::Image.get(image_ref)
    config = img.json.dig("Config") || {}
    labels = config["Labels"] || {}
    envs   = config["Env"] || []

    # Check OCI label first (set by docker/metadata-action)
    version = labels["org.opencontainers.image.version"]
    return version if version.present?

    # Fall back to BUILD_VERSION env (app image)
    version_entry = envs.find { |e| e.start_with?("BUILD_VERSION=") }
    version_entry&.split("=", 2)&.last.presence
  rescue Docker::Error::DockerError
    nil
  end

  # Fetches the latest release tag from GitHub (e.g. "v0.8.72").
  # Both the app and sandbox images share the same release tag.
  def latest_remote_tag(_repo, _token)
    @latest_release_tag ||= begin
      uri = URI("https://api.github.com/repos/#{OWNER}/Sandcastle/releases/latest")
      req = Net::HTTP::Get.new(uri)
      req["Accept"] = "application/vnd.github+json"

      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true,
                                 read_timeout: 10, open_timeout: 5) do |http|
        http.request(req)
      end

      return nil unless response.is_a?(Net::HTTPSuccess)
      JSON.parse(response.body)["tag_name"]
    rescue => e
      Rails.logger.warn("UpdateChecker: failed to fetch latest release: #{e.message}")
      nil
    end
  end

  # Queries GHCR for the latest manifest digest without pulling the image.
  def remote_manifest_digest(repo, token)
    return nil unless token

    uri = URI("https://#{GHCR_HOST}/v2/#{OWNER}/#{repo}/manifests/latest")
    req = Net::HTTP::Get.new(uri)
    req["Authorization"] = "Bearer #{token}"
    req["Accept"]        = "application/vnd.docker.distribution.manifest.list.v2+json," \
                           "application/vnd.oci.image.index.v1+json," \
                           "application/vnd.docker.distribution.manifest.v2+json," \
                           "application/vnd.oci.image.manifest.v1+json"

    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true,
                               read_timeout: 10, open_timeout: 5) do |http|
      http.request(req)
    end

    response["docker-content-digest"] || response["Docker-Content-Digest"]
  rescue => e
    Rails.logger.warn("UpdateChecker: failed to fetch remote digest for #{repo}: #{e.message}")
    nil
  end

  # GHCR grants anonymous tokens for public repositories.
  def fetch_anonymous_token(repo)
    uri = URI("https://#{GHCR_HOST}/token")
    uri.query = URI.encode_www_form(
      scope:   "repository:#{OWNER}/#{repo}:pull",
      service: GHCR_HOST
    )
    response = Net::HTTP.get_response(uri)
    return nil unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)["token"]
  rescue => e
    Rails.logger.warn("UpdateChecker: failed to fetch anonymous token: #{e.message}")
    nil
  end
end
