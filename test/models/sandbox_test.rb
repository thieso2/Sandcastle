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

  test "hostname includes project name when present" do
    sandbox = @user.sandboxes.build(
      name: "testbox",
      project_name: "alpha",
      status: "pending",
      image: SandboxManager::DEFAULT_IMAGE
    )

    assert_equal "testbox-alpha", sandbox.hostname
    assert_equal "alice-testbox", sandbox.full_name
  end
end
