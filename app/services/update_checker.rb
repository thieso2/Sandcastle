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
    {
      app:        image_status(APP_REPO, "ghcr.io/#{OWNER}/#{APP_REPO}:latest"),
      sandbox:    image_status(BOX_REPO, "ghcr.io/#{OWNER}/#{BOX_REPO}:latest"),
      checked_at: Time.current
    }
  rescue => e
    Rails.logger.error("UpdateChecker#perform_check failed: #{e.message}")
    { error: e.message, checked_at: Time.current }
  end

  def image_status(repo, local_ref)
    local_digest  = local_repo_digest(local_ref)
    remote_digest = remote_manifest_digest(repo)
    built_at      = local_image_built_at(local_ref)

    {
      local_digest:     local_digest,
      remote_digest:    remote_digest,
      built_at:         built_at,
      update_available: local_digest.present? && remote_digest.present? && local_digest != remote_digest
    }
  rescue => e
    Rails.logger.warn("UpdateChecker#image_status(#{repo}) failed: #{e.message}")
    { error: e.message }
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

  # Reads BUILD_DATE from image labels/env so we can show "built X ago".
  def local_image_built_at(image_ref)
    img    = Docker::Image.get(image_ref)
    config = img.json.dig("Config") || {}
    labels = config["Labels"] || {}

    date_str = labels["org.opencontainers.image.created"] ||
               labels["BUILD_DATE"]

    if date_str.nil?
      env_entry = (config["Env"] || []).find { |e| e.start_with?("BUILD_DATE=") }
      date_str  = env_entry&.split("=", 2)&.last
    end

    date_str ? Time.zone.parse(date_str) : nil
  rescue Docker::Error::DockerError, ArgumentError, TypeError
    nil
  end

  # Queries GHCR for the latest manifest digest without pulling the image.
  def remote_manifest_digest(repo)
    token = fetch_anonymous_token(repo)
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
