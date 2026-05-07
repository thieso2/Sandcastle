require "test_helper"

class SandboxEntrypointCaddyTest < ActiveSupport::TestCase
  test "entrypoint generates mkcert certificate and Caddy routes for exact and wildcard sandbox DNS names" do
    entrypoint = Rails.root.join("images/sandbox/entrypoint.sh").read

    assert_includes entrypoint, "mkcert \\"
    assert_includes entrypoint, "\"$CADDY_DNS_NAME\" \"*.$CADDY_DNS_NAME\" \\"
    assert_includes entrypoint, "http://$CADDY_DNS_NAME, http://*.$CADDY_DNS_NAME {"
    assert_includes entrypoint, "https://$CADDY_DNS_NAME, https://*.$CADDY_DNS_NAME {"
    assert_includes entrypoint, "tls /etc/sandcastle/caddy/certs/sandbox.pem /etc/sandcastle/caddy/certs/sandbox-key.pem"
  end
end
