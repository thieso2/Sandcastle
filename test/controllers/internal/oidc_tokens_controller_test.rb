require "test_helper"

class Internal::OidcTokensControllerTest < ActionDispatch::IntegrationTest
  setup do
    @test_key = OpenSSL::PKey::RSA.new(2048)
    ENV["OIDC_PRIVATE_KEY_PEM"] = @test_key.to_pem
    ENV["SANDCASTLE_HOST"] = "test.sandcastle.example"
    OidcSigner.reset!

    @sandbox = sandboxes(:alice_running)
    @sandbox.update!(oidc_enabled: true, status: "running")
    @runtime_token = @sandbox.rotate_oidc_secret!
    host! "sandcastle-web"
  end

  teardown do
    ENV.delete("OIDC_PRIVATE_KEY_PEM")
    ENV.delete("SANDCASTLE_HOST")
    OidcSigner.reset!
  end

  test "mints an OIDC token for a valid sandbox runtime token" do
    post "/internal/oidc/token",
      params: { audience: "gcp-audience" },
      headers: { "Authorization" => "Bearer #{@runtime_token}" }

    assert_response :success
    body = response.parsed_body
    assert body["token"].present?
    assert_equal "https://test.sandcastle.example", body["issuer"]
    assert_equal "sandcastle:user:alice:sandbox:devbox", body["subject"]

    payload, = OidcSigner.decode(body["token"])
    assert_equal "gcp-audience", payload["aud"]
    assert_equal "sandcastle:user:alice:sandbox:devbox", payload["sub"]
  end

  test "rejects invalid runtime token" do
    post "/internal/oidc/token",
      params: { audience: "gcp-audience" },
      headers: { "Authorization" => "Bearer sc_oidc_#{@sandbox.id}_bad" }

    assert_response :unauthorized
  end

  test "rejects missing audience" do
    post "/internal/oidc/token",
      params: {},
      headers: { "Authorization" => "Bearer #{@runtime_token}" }

    assert_response :unprocessable_entity
  end

  test "rejects disabled sandbox" do
    @sandbox.update!(oidc_enabled: false)

    post "/internal/oidc/token",
      params: { audience: "gcp-audience" },
      headers: { "Authorization" => "Bearer #{@runtime_token}" }

    assert_response :unauthorized
  end

  test "rejects stopped sandbox" do
    @sandbox.update!(status: "stopped")

    post "/internal/oidc/token",
      params: { audience: "gcp-audience" },
      headers: { "Authorization" => "Bearer #{@runtime_token}" }

    assert_response :conflict
  end

  test "rejects public host" do
    host! "test.sandcastle.example"

    post "/internal/oidc/token",
      params: { audience: "gcp-audience" },
      headers: { "Authorization" => "Bearer #{@runtime_token}" }

    assert_response :not_found
  end
end
