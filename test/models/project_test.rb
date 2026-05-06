require "test_helper"

class ProjectTest < ActiveSupport::TestCase
  setup { @user = users(:one) }

  test "valid record" do
    project = @user.projects.build(
      name: "myproj",
      path: "projects/myproj",
      image: SandboxManager::DEFAULT_IMAGE,
      docker_enabled: true,
      vnc_enabled: true,
      vnc_geometry: "1280x900",
      vnc_depth: 24,
      ssh_start_tmux: true
    )

    assert project.valid?, project.errors.full_messages.inspect
  end

  test "rejects root or traversal paths" do
    assert_not @user.projects.build(name: "bad1", path: ".", image: SandboxManager::DEFAULT_IMAGE).valid?
    assert_not @user.projects.build(name: "bad2", path: "../escape", image: SandboxManager::DEFAULT_IMAGE).valid?
    assert_not @user.projects.build(name: "bad3", path: "/abs", image: SandboxManager::DEFAULT_IMAGE).valid?
  end

  test "apply_to_sandbox scopes home and persisted to project path" do
    project = @user.projects.create!(
      name: "myproj",
      path: "projects/myproj",
      image: "ghcr.io/thieso2/sandcastle-sandbox:latest",
      docker_enabled: false,
      vnc_enabled: false,
      tailscale: true,
      smb_enabled: false,
      ssh_start_tmux: false
    )
    sandbox = @user.sandboxes.build(name: "box", status: "pending", image: SandboxManager::DEFAULT_IMAGE)

    project.apply_to_sandbox(sandbox)

    assert_not sandbox.mount_home
    assert_equal "projects/myproj", sandbox.home_path
    assert_equal "projects/myproj", sandbox.data_path
    assert_equal project.image, sandbox.image
    assert_equal project.docker_enabled, sandbox.docker_enabled
  end

  test "default project can omit path and applies user-wide defaults" do
    @user.update!(default_mount_home: true, default_data_path: "workspace", default_oidc_enabled: true)
    project = Project.create_default_for!(@user)
    sandbox = @user.sandboxes.build(name: "box", status: "pending", image: SandboxManager::DEFAULT_IMAGE)

    assert project.valid?, project.errors.full_messages.inspect
    assert_nil project.path

    project.apply_to_sandbox(sandbox)

    assert_nil sandbox.project_name
    assert sandbox.mount_home
    assert_nil sandbox.home_path
    assert_equal "workspace", sandbox.data_path
    assert sandbox.oidc_enabled
  end

  test "project applies gcp oidc settings to sandbox" do
    config = @user.gcp_oidc_configs.create!(
      name: "prod",
      project_id: "test-project-123",
      project_number: "123456789012",
      workload_identity_pool_id: "sandcastle",
      workload_identity_provider_id: "sandcastle"
    )
    project = @user.projects.create!(
      name: "cloud",
      path: "projects/cloud",
      image: SandboxManager::DEFAULT_IMAGE,
      gcp_oidc_enabled: true,
      gcp_oidc_config: config,
      gcp_service_account_email: "sandcastle-reader@test-project-123.iam.gserviceaccount.com",
      gcp_principal_scope: "sandbox",
      gcp_roles: [ "roles/viewer", "roles/storage.objectViewer" ]
    )
    sandbox = @user.sandboxes.build(name: "box", status: "pending", image: SandboxManager::DEFAULT_IMAGE)

    project.apply_to_sandbox(sandbox)

    assert sandbox.oidc_enabled
    assert sandbox.gcp_oidc_enabled
    assert_equal config, sandbox.gcp_oidc_config
    assert_equal "sandcastle-reader@test-project-123.iam.gserviceaccount.com", sandbox.gcp_service_account_email
    assert_equal "sandbox", sandbox.gcp_principal_scope
    assert_equal [ "roles/viewer", "roles/storage.objectViewer" ], sandbox.gcp_roles
  end
end
