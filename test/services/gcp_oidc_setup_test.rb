require "test_helper"

class GcpOidcSetupTest < ActiveSupport::TestCase
  setup do
    ENV["SANDCASTLE_HOST"] = "sandcastle.example.com"
    @user = users(:one)
    @gcp_config = @user.gcp_oidc_configs.create!(
      name: "test",
      project_id: "test-project-123",
      project_number: "123456789012",
      workload_identity_pool_id: "sandcastle",
      workload_identity_provider_id: "sandcastle",
      workload_identity_location: "global"
    )
    @sandbox = sandboxes(:alice_stopped)
    @sandbox.update!(
      oidc_enabled: true,
      gcp_oidc_enabled: true,
      gcp_oidc_config: @gcp_config,
      gcp_service_account_email: "sandbox@test-project-123.iam.gserviceaccount.com",
      gcp_principal_scope: "sandbox",
      gcp_roles: [ "roles/viewer" ]
    )
  end

  teardown do
    ENV.delete("SANDCASTLE_HOST")
  end

  test "builds sandbox scoped setup data" do
    setup = GcpOidcSetup.new(user: @user, sandbox: @sandbox)

    assert setup.configured?
    assert_equal "//iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/sandcastle/providers/sandcastle", setup.audience
    assert_equal "principalSet://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/sandcastle/attribute.sandbox_id/#{@sandbox.id}", setup.principal
    assert_includes setup.commands[:create_provider], "--issuer-uri=https://sandcastle.example.com"
    assert_includes setup.commands[:bind_service_account], "roles/iam.workloadIdentityUser"
    assert_equal [ "roles/viewer" ], setup.commands[:grant_roles].map { |cmd| cmd[/--role=(\S+)/, 1] }
  end

  test "builds user scoped principal" do
    @sandbox.update!(gcp_principal_scope: "user")

    setup = GcpOidcSetup.new(user: @user, sandbox: @sandbox)

    assert_equal "principalSet://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/sandcastle/attribute.user/alice", setup.principal
  end

  test "credential config uses executable sourced credentials" do
    config = GcpOidcSetup.new(user: @user, sandbox: @sandbox).credential_config

    assert_equal "external_account", config[:type]
    assert_equal GcpOidcSetup::SUBJECT_TOKEN_TYPE, config[:subject_token_type]
    assert_includes config.dig(:credential_source, :executable, :command), "sandcastle-oidc gcp executable"
    assert_includes config[:service_account_impersonation_url], @sandbox.gcp_service_account_email
  end

  test "builds general setup for a reusable config" do
    setup = GcpOidcSetup.new(user: @user, config: @gcp_config)

    assert setup.configured?
    assert_equal "test", setup.as_json[:config_name]
    assert_equal "principalSet://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/sandcastle/attribute.user/alice", setup.principal
    assert_equal "sandcastle-reader@test-project-123.iam.gserviceaccount.com", setup.as_json[:default_service_account_email]
    assert_includes setup.commands[:create_default_service_account], "gcloud iam service-accounts create sandcastle-reader"
    assert_includes setup.commands[:grant_default_roles].join("\n"), "--role=roles/viewer"
    assert_includes setup.commands[:bind_service_account], "attribute.user/alice"
    assert_includes setup.commands[:create_provider], "--workload-identity-pool=sandcastle"
  end

  test "sandbox uses config default service account when no override is set" do
    @sandbox.update!(gcp_service_account_email: nil, gcp_roles: [])

    setup = GcpOidcSetup.new(user: @user, sandbox: @sandbox)

    assert @sandbox.gcp_oidc_configured?
    assert_equal "sandcastle-reader@test-project-123.iam.gserviceaccount.com", setup.as_json[:service_account_email]
    assert_equal "default", setup.as_json[:service_account_source]
    assert_includes setup.commands[:bind_service_account], "sandcastle-reader@test-project-123.iam.gserviceaccount.com"
  end
end
