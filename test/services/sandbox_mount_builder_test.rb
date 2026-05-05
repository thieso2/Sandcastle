require "test_helper"

class SandboxMountBuilderTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
    @sandbox = sandboxes(:alice_running)
  end

  test "builds direct home and data mounts" do
    @sandbox.mount_home = true
    @sandbox.data_path = "projects/app"

    records = SandboxMountBuilder.new(user: @user, sandbox: @sandbox).direct_mount_attributes

    assert_equal 2, records.size
    assert_includes records.map { |r| r[:mount_type] }, "home"
    assert_includes records.map { |r| r[:mount_type] }, "data"
    assert_equal "/home/#{@user.name}", records.find { |r| r[:mount_type] == "home" }[:target_path]
    assert_equal "/persisted", records.find { |r| r[:mount_type] == "data" }[:target_path]
  end

  test "builds persisted path mounts when home is not mounted" do
    path = ".builder-test-#{SecureRandom.hex(4)}"
    @user.persisted_paths.create!(path: path)
    @sandbox.mount_home = false
    @sandbox.data_path = nil

    records = SandboxMountBuilder.new(user: @user, sandbox: @sandbox).direct_mount_attributes

    record = records.find { |r| r[:logical_path] == path }
    assert_equal "persisted_path", record[:mount_type]
    assert_equal "/home/#{@user.name}/#{path}", record[:target_path]
  end

  test "does not build persisted path mounts when full home is mounted" do
    path = ".builder-home-test-#{SecureRandom.hex(4)}"
    @user.persisted_paths.create!(path: path)
    @sandbox.mount_home = true
    @sandbox.data_path = nil

    records = SandboxMountBuilder.new(user: @user, sandbox: @sandbox).direct_mount_attributes

    assert_nil records.find { |r| r[:logical_path] == path }
  end
end
