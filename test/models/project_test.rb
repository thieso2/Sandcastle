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
end
