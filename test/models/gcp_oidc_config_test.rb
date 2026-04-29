require "test_helper"

class GcpOidcConfigTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
  end

  test "normalizes fields and falls back to project number selector" do
    config = @user.gcp_oidc_configs.create!(
      name: " prod ",
      project_id: "",
      project_number: " 123456789012 ",
      workload_identity_pool_id: " sandcastle ",
      workload_identity_provider_id: " sandcastle ",
      workload_identity_location: ""
    )

    assert_equal "prod", config.name
    assert_nil config.project_id
    assert_equal "123456789012", config.project_selector
    assert_equal "global", config.workload_identity_location
  end

  test "derives default read-only service account from project id" do
    config = @user.gcp_oidc_configs.create!(
      name: "prod",
      project_id: "test-project-123",
      project_number: "123456789012",
      workload_identity_pool_id: "sandcastle",
      workload_identity_provider_id: "sandcastle"
    )

    assert_equal "sandcastle-reader@test-project-123.iam.gserviceaccount.com", config.default_service_account_email
    assert_equal "sandcastle-reader", config.default_service_account_id
  end

  test "requires unique names per user" do
    @user.gcp_oidc_configs.create!(
      name: "prod",
      project_number: "123456789012",
      workload_identity_pool_id: "sandcastle",
      workload_identity_provider_id: "sandcastle"
    )

    duplicate = @user.gcp_oidc_configs.build(
      name: "prod",
      project_number: "123456789013",
      workload_identity_pool_id: "sandcastle",
      workload_identity_provider_id: "sandcastle"
    )

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:name], "has already been taken"
  end

  test "requires global location" do
    config = @user.gcp_oidc_configs.build(
      name: "prod",
      project_number: "123456789012",
      workload_identity_pool_id: "sandcastle",
      workload_identity_provider_id: "sandcastle",
      workload_identity_location: "local"
    )

    assert_not config.valid?
    assert_includes config.errors[:workload_identity_location], "must be global for GCP Workload Identity Federation"
  end
end
