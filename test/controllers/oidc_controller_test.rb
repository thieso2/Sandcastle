require "test_helper"

class OidcControllerTest < ActionDispatch::IntegrationTest
  setup do
    @test_key = OpenSSL::PKey::RSA.new(2048)
    ENV["OIDC_PRIVATE_KEY_PEM"] = @test_key.to_pem
    ENV["SANDCASTLE_HOST"] = "test.sandcastle.example"
    OidcSigner.reset!
  end

  teardown do
    ENV.delete("OIDC_PRIVATE_KEY_PEM")
    ENV.delete("SANDCASTLE_HOST")
    OidcSigner.reset!
  end

  test "discovery endpoint is publicly reachable without auth" do
    get "/.well-known/openid-configuration"
    assert_response :success
    assert_equal "application/json", response.media_type
    doc = response.parsed_body
    assert_equal "https://test.sandcastle.example", doc["issuer"]
    assert_equal "https://test.sandcastle.example/oauth/jwks", doc["jwks_uri"]
    assert_includes doc["id_token_signing_alg_values_supported"], "RS256"
  end

  test "jwks endpoint is publicly reachable without auth" do
    get "/oauth/jwks"
    assert_response :success
    assert_equal "application/json", response.media_type
    body = response.parsed_body
    assert body["keys"].is_a?(Array)
    assert_equal 1, body["keys"].size
    assert_equal OidcSigner.kid, body["keys"].first["kid"]
  end

  test "jwks response is cacheable" do
    get "/oauth/jwks"
    assert_match(/public/, response.headers["Cache-Control"].to_s)
    assert_match(/max-age=\d+/, response.headers["Cache-Control"].to_s)
  end

  test "a minted JWT validates against the served JWKS" do
    user = users(:one)
    sandbox = sandboxes(:alice_running)
    audience = "//iam.googleapis.com/test-audience"
    token = OidcSigner.mint(user: user, sandbox: sandbox, audience: audience)

    get "/oauth/jwks"
    served_jwks = response.parsed_body

    # Re-verify the token using only what the JWKS endpoint exposes —
    # this is exactly what GCP STS does on its side.
    jwks_loader = ->(_opts) { served_jwks.deep_symbolize_keys }
    payload, _ = JWT.decode(token, nil, true,
      algorithms: [ "RS256" ],
      jwks: jwks_loader
    )
    assert_equal audience, payload["aud"]
    assert_equal "sandcastle:user:alice:sandbox:devbox", payload["sub"]
  end
end
