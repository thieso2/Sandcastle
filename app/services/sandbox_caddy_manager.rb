require "shellwords"

class SandboxCaddyManager
  class Error < StandardError; end

  # Re-runs sc-caddy-reconfigure inside the sandbox so its in-container
  # Caddy regenerates the cert (mkcert) and Caddyfile from the current
  # alias list, then hot-reloads. Used by SandboxAliases controllers when
  # an alias is added or removed so users don't have to restart the
  # sandbox.
  def reconfigure(sandbox)
    return unless sandbox.caddy_enabled? && sandbox.status == "running"
    return if sandbox.container_id.blank?

    container = Docker::Container.get(sandbox.container_id)
    aliases = SandboxAlias.expanded_names_for(sandbox).join(",")
    script = "export SANDCASTLE_DNS_ALIASES=#{Shellwords.escape(aliases)}; exec /usr/local/bin/sc-caddy-reconfigure"
    stdout, stderr, status = container.exec([ "bash", "-c", script ], user: "root")
    exit_code = status.is_a?(Array) ? status.first : status
    return if exit_code == 0

    err = (Array(stderr) + Array(stdout)).join.strip
    raise Error, "sc-caddy-reconfigure failed (exit #{exit_code}) for sandbox #{sandbox.id}: #{err}"
  rescue Docker::Error::NotFoundError
    nil
  rescue Docker::Error::DockerError => e
    raise Error, "Docker error reconfiguring Caddy in sandbox #{sandbox.id}: #{e.message}"
  end
end
