require "test_helper"

class OidcSignerTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)          # alice
    @sandbox = sandboxes(:alice_running) # name "devbox"
    @audience = "//iam.googleapis.com/projects/1/locations/global/workloadIdentityPools/p/providers/pp"

    # Throwaway RSA key — don't require a real OIDC_PRIVATE_KEY_PEM in CI.
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

  # --- key + metadata ---

  test "private_key raises when env var is missing" do
    ENV.delete("OIDC_PRIVATE_KEY_PEM")
    OidcSigner.reset!
    assert_raises(OidcSigner::MissingKey) { OidcSigner.private_key }
  end

  test "private_key loads from a base64-encoded PEM" do
    ENV["OIDC_PRIVATE_KEY_PEM"] = Base64.strict_encode64(@test_key.to_pem)
    OidcSigner.reset!
    assert_equal @test_key.n, OidcSigner.private_key.n
  end

  test "private_key raises on garbage input" do
    ENV["OIDC_PRIVATE_KEY_PEM"] = "not a key"
    OidcSigner.reset!
    assert_raises(OidcSigner::MissingKey) { OidcSigner.private_key }
  end

  test "kid is deterministic for a given key" do
    a = OidcSigner.kid
    OidcSigner.reset!
    b = OidcSigner.kid
    assert_equal a, b
    assert_match(/\A[0-9a-f]{8}\z/, a)
  end

  test "issuer is built from SANDCASTLE_HOST" do
    assert_equal "https://test.sandcastle.example", OidcSigner.issuer
  end

  # --- discovery + jwks ---

  test "discovery document has the required OIDC fields" do
    doc = OidcSigner.discovery_document
    assert_equal "https://test.sandcastle.example", doc[:issuer]
    assert_equal "https://test.sandcastle.example/oauth/jwks", doc[:jwks_uri]
    assert_includes doc[:id_token_signing_alg_values_supported], "RS256"
  end

  test "jwks exports one key whose kid matches the signer's" do
    keys = OidcSigner.jwks[:keys]
    assert_equal 1, keys.size
    assert_equal OidcSigner.kid, keys.first[:kid]
    assert_equal "RSA", keys.first[:kty]
    assert_equal "sig", keys.first[:use]
  end

  # --- mint ---

  test "mints a JWT that verifies against its own JWKS" do
    token = OidcSigner.mint(user: @user, sandbox: @sandbox, audience: @audience)
    payload, header = OidcSigner.decode(token)
    assert_equal "RS256", header["alg"]
    assert_equal OidcSigner.kid, header["kid"]
    assert_equal "sandcastle:user:alice:sandbox:devbox", payload["sub"]
    assert_equal @audience, payload["aud"]
    assert_equal "alice", payload["user"]
    assert_equal "devbox", payload["sandbox"]
    assert_equal @sandbox.id, payload["sandbox_id"]
    assert_equal @user.email_address, payload["email"]
    assert_equal "https://test.sandcastle.example", payload["iss"]
    assert payload["jti"].present?
  end

  test "mint defaults to a 15-minute expiry backdated 30s" do
    before = Time.current.to_i
    token = OidcSigner.mint(user: @user, sandbox: @sandbox, audience: @audience)
    payload, _ = OidcSigner.decode(token)
    iat = payload["iat"]
    exp = payload["exp"]
    assert iat <= before, "iat should be backdated by ~30s (got iat=#{iat}, before=#{before})"
    # exp is iat+ttl+30s; allow a wide window to avoid test flake
    assert_in_delta 15 * 60 + 30, exp - iat, 60
  end

  test "mint rejects mismatched user and sandbox" do
    other_user = users(:two)
    assert_raises(ArgumentError) do
      OidcSigner.mint(user: other_user, sandbox: @sandbox, audience: @audience)
    end
  end

  test "mint rejects empty audience" do
    assert_raises(ArgumentError) do
      OidcSigner.mint(user: @user, sandbox: @sandbox, audience: "")
    end
  end

  test "sub stays under GCP's 127 char limit even for max-length names" do
    # User name max 31, sandbox name max 63 (per model validations).
    max_user = "a" + "b" * 30            # 31
    max_sandbox = "a" + "b" * 62         # 63
    # Build the string we'd put in `sub` without actually creating records —
    # the length invariant is what we care about.
    sub = "sandcastle:user:#{max_user}:sandbox:#{max_sandbox}"
    assert_operator sub.length, :<=, OidcSigner::SUBJECT_MAX,
      "worst-case sub is #{sub.length} chars, exceeds #{OidcSigner::SUBJECT_MAX}"
  end

  test "exp - iat is <= 24h (GCP requirement)" do
    token = OidcSigner.mint(user: @user, sandbox: @sandbox, audience: @audience, ttl: 1.hour)
    payload, _ = OidcSigner.decode(token)
    assert_operator payload["exp"] - payload["iat"], :<=, 24 * 3600 + 60
  end
end
