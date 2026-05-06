require "test_helper"

class Api::GcpOidcConfigsControllerTest < ActionDispatch::IntegrationTest
  setup do
    ENV["SANDCASTLE_HOST"] = "sandcastle.example.com"
    @user = users(:one)
    _token, @raw_token = ApiToken.generate_for(@user, name: "test")
    @headers = { "Authorization" => "Bearer #{@raw_token}" }
  end

  teardown do
    ENV.delete("SANDCASTLE_HOST")
  end

  test "creates and returns GCP OIDC configs" do
    post "/api/gcp_oidc_configs",
      params: {
        name: "prod",
        project_id: "test-project-123",
        project_number: "123456789012",
        workload_identity_pool_id: "sandcastle",
        workload_identity_provider_id: "sandcastle",
        workload_identity_location: "global"
      },
      headers: @headers

    assert_response :created
    body = response.parsed_body
    assert_equal "prod", body["name"]
    assert_equal "test-project-123", body["project_id"]
    assert_equal "sandcastle-reader@test-project-123.iam.gserviceaccount.com", body["default_service_account_email"]
    assert_equal "//iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/sandcastle/providers/sandcastle", body.dig("setup", "audience")

    get "/api/gcp_oidc_configs", headers: @headers
    assert_response :success
    assert_equal [ "prod" ], response.parsed_body.map { |config| config["name"] }
  end

  test "updates and deletes GCP OIDC configs" do
    config = create_config!

    patch "/api/gcp_oidc_configs/#{config.id}",
      params: { project_id: "renamed-project" },
      headers: @headers

    assert_response :success
    assert_equal "renamed-project", response.parsed_body["project_id"]

    delete "/api/gcp_oidc_configs/#{config.id}", headers: @headers

    assert_response :success
    assert_nil @user.gcp_oidc_configs.find_by(id: config.id)
  end

  test "configures sandbox GCP identity and returns setup" do
    config = create_config!
    sandbox = sandboxes(:alice_stopped)
    sandbox.update!(oidc_enabled: true)

    patch "/api/sandboxes/#{sandbox.id}/gcp_identity",
      params: {
        gcp_oidc_enabled: true,
        gcp_oidc_config_id: config.id,
        gcp_service_account_email: "sandbox@test-project-123.iam.gserviceaccount.com",
        gcp_principal_scope: "sandbox",
        gcp_roles: [ "roles/viewer" ]
      },
      headers: @headers

    assert_response :success
    body = response.parsed_body
    assert body.dig("sandbox", "gcp_oidc_configured")
    assert_equal config.id, body.dig("sandbox", "gcp_oidc_config_id")
    assert_includes body.dig("setup", "principal"), "/attribute.sandbox_id/#{sandbox.id}"
    assert_includes body.dig("setup", "shell"), "gcloud iam service-accounts add-iam-policy-binding"
  end

  test "rejects GCP identity edits while sandbox is running" do
    sandbox = sandboxes(:alice_running)

    patch "/api/sandboxes/#{sandbox.id}/gcp_identity",
      params: { gcp_oidc_enabled: true },
      headers: @headers

    assert_response :conflict
  end

  private

  def create_config!
    @user.gcp_oidc_configs.create!(
      name: "prod",
      project_id: "test-project-123",
      project_number: "123456789012",
      workload_identity_pool_id: "sandcastle",
      workload_identity_provider_id: "sandcastle",
      workload_identity_location: "global"
    )
  end
end
