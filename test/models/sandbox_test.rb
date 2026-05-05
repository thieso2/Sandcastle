require "test_helper"

class SandboxTest < ActiveSupport::TestCase
  setup { @user = users(:one) }

  test "rejects combining full home and home_path" do
    sandbox = @user.sandboxes.build(
      name: "testbox",
      status: "pending",
      image: SandboxManager::DEFAULT_IMAGE,
      mount_home: true,
      home_path: "projects/demo"
    )

    assert_not sandbox.valid?
    assert_includes sandbox.errors[:home_path], "cannot be combined with full home mount"
  end

  test "derives project_path when home and data paths match" do
    sandbox = @user.sandboxes.build(
      name: "testbox",
      status: "pending",
      image: SandboxManager::DEFAULT_IMAGE,
      home_path: "projects/demo",
      data_path: "projects/demo"
    )

    assert sandbox.valid?, sandbox.errors.full_messages.inspect
    assert_equal "projects/demo", sandbox.project_path
  end

  test "hostname, full_name, and display_name include project name when present" do
    sandbox = @user.sandboxes.build(
      name: "testbox",
      project_name: "alpha",
      status: "pending",
      image: SandboxManager::DEFAULT_IMAGE
    )

    assert_equal "testbox-alpha", sandbox.hostname
    assert_equal "alice-testbox-alpha", sandbox.full_name
    assert_equal "alpha:testbox", sandbox.display_name
  end

  test "display_name falls back to name when project is absent" do
    sandbox = @user.sandboxes.build(
      name: "testbox",
      status: "pending",
      image: SandboxManager::DEFAULT_IMAGE
    )

    assert_equal "testbox", sandbox.display_name
  end

  test "name uniqueness is scoped per project" do
    @user.sandboxes.create!(
      name: "tmp",
      status: "running",
      image: SandboxManager::DEFAULT_IMAGE,
      project_name: "alpha"
    )

    other = @user.sandboxes.build(
      name: "tmp",
      status: "running",
      image: SandboxManager::DEFAULT_IMAGE,
      project_name: "beta"
    )
    assert other.valid?, other.errors.full_messages.inspect

    same = @user.sandboxes.build(
      name: "tmp",
      status: "running",
      image: SandboxManager::DEFAULT_IMAGE,
      project_name: "alpha"
    )
    assert_not same.valid?
    assert_includes same.errors[:name], "has already been taken"
  end
end
