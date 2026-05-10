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
      caddy_enabled: true,
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
    assert sandbox.caddy_enabled?
    assert_equal config, sandbox.gcp_oidc_config
    assert_equal true, response.parsed_body["caddy_enabled"]
    assert_equal "testbox-io26", response.parsed_body["hostname"]
    assert_equal DnsManager.new.hostname_for(sandbox), response.parsed_body["primary_dns_name"]
  end

  test "connect response includes primary dns name" do
    sandbox = @user.sandboxes.find_by!(name: "devbox")
    sandbox.update!(project_name: "alpha", tailscale: true)

    original = SandboxManager.instance_method(:wait_for_tailscale_ip)
    SandboxManager.define_method(:wait_for_tailscale_ip) { |sandbox:, **| "10.206.10.9" }
    begin
      post "/api/sandboxes/#{sandbox.id}/connect", headers: @headers
    ensure
      SandboxManager.define_method(:wait_for_tailscale_ip, original)
    end

    assert_response :success
    assert_equal DnsManager.new.hostname_for(sandbox), response.parsed_body["primary_dns_name"]
    assert_equal "10.206.10.9", response.parsed_body["tailscale_ip"]
  end
end
