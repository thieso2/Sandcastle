require "test_helper"

class Api::SandboxesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    _token, @raw_token = ApiToken.generate_for(@user, name: "test")
    @headers = { "Authorization" => "Bearer #{@raw_token}" }
  end

  test "create with project_path matching saved project inherits oidc settings" do
    config = @user.gcp_oidc_configs.create!(
      name: "prod",
      project_id: "test-project-123",
      project_number: "123456789012",
      workload_identity_pool_id: "sandcastle",
      workload_identity_provider_id: "sandcastle"
    )
    project = @user.projects.create!(
      name: "io26",
      path: "IO26",
      image: SandboxManager::DEFAULT_IMAGE,
      vnc_enabled: true,
      vnc_geometry: "1280x900",
      vnc_depth: 24,
      docker_enabled: true,
      ssh_start_tmux: true,
      oidc_enabled: true,
      gcp_oidc_enabled: true,
      gcp_oidc_config: config,
      gcp_principal_scope: "user"
    )

    post "/api/sandboxes",
      params: {
        name: "testbox",
        project_path: "io26",
        vnc_enabled: true,
        docker_enabled: true
      },
      headers: @headers

    assert_response :created
    sandbox = @user.sandboxes.find_by!(name: "testbox")
    assert_equal project.name, sandbox.project_name
    assert_equal project.path, sandbox.home_path
    assert_equal project.path, sandbox.data_path
    assert sandbox.oidc_enabled?
    assert sandbox.gcp_oidc_enabled?
    assert_equal config, sandbox.gcp_oidc_config
  end
end
