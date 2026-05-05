require "test_helper"

class SandboxMountTest < ActiveSupport::TestCase
  setup { @sandbox = sandboxes(:alice_running) }

  test "valid direct home mount" do
    mount = @sandbox.sandbox_mounts.build(
      mount_type: "home",
      target_path: "/home/alice",
      master_path: "/data/users/alice/home",
      source_path: "/data/users/alice/home"
    )

    assert mount.valid?, mount.errors.full_messages.inspect
    assert mount.direct?
  end

  test "snapshot mounts require base and work paths" do
    mount = @sandbox.sandbox_mounts.build(
      mount_type: "home",
      storage_mode: "snapshot",
      target_path: "/home/alice",
      master_path: "/data/users/alice/home",
      source_path: "/data/reconcile/1/work/home"
    )

    assert_not mount.valid?
    assert_includes mount.errors[:base_path].to_s, "present"
    assert_includes mount.errors[:work_path].to_s, "present"
  end

  test "snapshot mount accepts base and work paths" do
    mount = @sandbox.sandbox_mounts.build(
      mount_type: "data",
      storage_mode: "snapshot",
      logical_path: "projects/app",
      target_path: "/persisted",
      master_path: "/data/users/alice/data/projects/app",
      source_path: "/data/reconcile/1/work/data",
      base_path: "/data/reconcile/1/base/data",
      work_path: "/data/reconcile/1/work/data"
    )

    assert mount.valid?, mount.errors.full_messages.inspect
    assert mount.snapshot?
  end

  test "rejects relative host and container paths" do
    mount = @sandbox.sandbox_mounts.build(
      mount_type: "home",
      target_path: "home/alice",
      master_path: "data/users/alice/home",
      source_path: "data/users/alice/home"
    )

    assert_not mount.valid?
    assert_includes mount.errors[:target_path].to_s, "absolute"
    assert_includes mount.errors[:master_path].to_s, "absolute"
    assert_includes mount.errors[:source_path].to_s, "absolute"
  end

  test "rejects unsafe logical paths" do
    assert_not build_with_logical_path("/absolute").valid?
    assert_not build_with_logical_path("../escape").valid?
    assert_not build_with_logical_path("a//b").valid?
  end

  test "target path is unique per sandbox" do
    @sandbox.sandbox_mounts.create!(
      mount_type: "home",
      target_path: "/home/alice",
      master_path: "/data/users/alice/home",
      source_path: "/data/users/alice/home"
    )

    duplicate = @sandbox.sandbox_mounts.build(
      mount_type: "home",
      target_path: "/home/alice",
      master_path: "/data/users/alice/other-home",
      source_path: "/data/users/alice/other-home"
    )

    assert_not duplicate.valid?
  end

  test "bind_spec formats source and target paths" do
    mount = @sandbox.sandbox_mounts.build(
      mount_type: "home",
      target_path: "/home/alice",
      master_path: "/data/users/alice/home",
      source_path: "/data/reconcile/1/work/home"
    )

    assert_equal "/data/reconcile/1/work/home:/home/alice", mount.bind_spec
  end

  private

  def build_with_logical_path(path)
    @sandbox.sandbox_mounts.build(
      mount_type: "data",
      logical_path: path,
      target_path: "/persisted",
      master_path: "/data/users/alice/data/#{path}",
      source_path: "/data/users/alice/data/#{path}"
    )
  end
end
