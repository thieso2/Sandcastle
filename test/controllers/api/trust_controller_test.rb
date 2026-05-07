require "test_helper"

class Api::TrustControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    _token, @raw_token = ApiToken.generate_for(@user, name: "test")
    @headers = { "Authorization" => "Bearer #{@raw_token}" }
  end

  test "root_ca returns the public Sandcastle Caddy CA" do
    original = CaddyCertificateAuthority.method(:root_certificate_pem)
    CaddyCertificateAuthority.define_singleton_method(:root_certificate_pem) do
      "-----BEGIN CERTIFICATE-----\ntest\n-----END CERTIFICATE-----\n"
    end

    begin
      get "/api/trust/root_ca", headers: @headers
    ensure
      CaddyCertificateAuthority.define_singleton_method(:root_certificate_pem, original)
    end

    assert_response :success
    assert_equal "Sandcastle Caddy Root CA", response.parsed_body["name"]
    assert_includes response.parsed_body["pem"], "BEGIN CERTIFICATE"
  end

  test "root_ca reports certificate authority preparation failures as unavailable" do
    original = CaddyCertificateAuthority.method(:root_certificate_pem)
    CaddyCertificateAuthority.define_singleton_method(:root_certificate_pem) do
      raise CaddyCertificateAuthority::Error, "failed to prepare Caddy certificate authority: Permission denied"
    end

    begin
      get "/api/trust/root_ca", headers: @headers
    ensure
      CaddyCertificateAuthority.define_singleton_method(:root_certificate_pem, original)
    end

    assert_response :service_unavailable
    assert_includes response.parsed_body["error"], "failed to prepare Caddy certificate authority"
  end
end
