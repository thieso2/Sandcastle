require "test_helper"

class SandboxEntrypointCaddyTest < ActiveSupport::TestCase
  test "entrypoint generates mkcert certificate and Caddy routes for exact and wildcard sandbox DNS names" do
    entrypoint = Rails.root.join("images/sandbox/entrypoint.sh").read
    script = Rails.root.join("images/sandbox/sc-caddy-reconfigure.sh").read

    assert_includes entrypoint, "/usr/local/bin/sc-caddy-reconfigure"
    assert_includes script, "SAN_ARGS+=(\"$prefix\" \"*.$prefix\")"
    assert_includes script, 'HOSTS_HTTP+="http://$prefix, http://*.$prefix"'
    assert_includes script, 'HOSTS_HTTPS+="https://$prefix, https://*.$prefix"'
    assert_includes script, "mkcert \\"
    assert_includes script, "\"${SAN_ARGS[@]}\" \\"
    assert_includes script, "tls /etc/sandcastle/caddy/certs/sandbox.pem /etc/sandcastle/caddy/certs/sandbox-key.pem"
  end

  test "caddy reconfigure tolerates read-only mounted mkcert CA directory" do
    script = Rails.root.join("images/sandbox/sc-caddy-reconfigure.sh").read

    assert_includes script, "if [ ! -d /etc/sandcastle/caddy/mkcert ]; then"
    assert_includes script, "install -d -m 0700 /etc/sandcastle/caddy/mkcert"
  end

  test "entrypoint banner includes addressing and project metadata" do
    entrypoint = Rails.root.join("images/sandbox/entrypoint.sh").read

    assert_includes entrypoint, "_SC_RUNTIME_FILE=\"/etc/sandcastle/runtime\""
    assert_includes entrypoint, "SC_TAILSCALE_IP="
    assert_includes entrypoint, "SANDCASTLE_PROJECT_NAME"
    assert_includes entrypoint, "SANDCASTLE_PROJECT_PATH"
    assert_includes entrypoint, "print_setting \"tailscale\""
    assert_includes entrypoint, "print_setting \"dns\""
    assert_includes entrypoint, "print_setting \"project\""
    assert_includes entrypoint, "print_setting \"subdir\""
  end
end
