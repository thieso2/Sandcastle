require "test_helper"
require "tmpdir"

class SandboxMountReconcilerTest < ActiveSupport::TestCase
  setup do
    @root = Dir.mktmpdir
    @base = File.join(@root, "base")
    @work = File.join(@root, "work")
    @master = File.join(@root, "master")
    FileUtils.mkdir_p([ @base, @work, @master ])

    @sandbox = sandboxes(:alice_running)
    @mount = @sandbox.sandbox_mounts.create!(
      mount_type: "data",
      storage_mode: "snapshot",
      logical_path: ".",
      target_path: "/persisted",
      master_path: @master,
      source_path: @work,
      base_path: @base,
      work_path: @work
    )
  end

  teardown do
    FileUtils.rm_rf(@root)
  end

  test "classifies added modified deleted and conflicts" do
    write_all("same.txt", "same")
    write_all("modified.txt", "old")
    File.write(File.join(@work, "modified.txt"), "work")
    write_all("deleted.txt", "old")
    FileUtils.rm_f(File.join(@work, "deleted.txt"))
    File.write(File.join(@work, "added.txt"), "new")
    write_all("conflict.txt", "old")
    File.write(File.join(@work, "conflict.txt"), "work")
    File.write(File.join(@master, "conflict.txt"), "master")

    statuses = SandboxMountReconciler.new(@sandbox).changes.to_h { |c| [ c.path, c.status ] }

    assert_equal "modified", statuses["modified.txt"]
    assert_equal "deleted", statuses["deleted.txt"]
    assert_equal "added", statuses["added.txt"]
    assert_equal "conflict", statuses["conflict.txt"]
    assert_nil statuses["same.txt"]
  end

  test "applies selected work changes and deletions" do
    write_all("modified.txt", "old")
    File.write(File.join(@work, "modified.txt"), "work")
    write_all("deleted.txt", "old")
    FileUtils.rm_f(File.join(@work, "deleted.txt"))

    SandboxMountReconciler.new(@sandbox).apply!([
      { mount_id: @mount.id, path: "modified.txt", action: "use_work" },
      { mount_id: @mount.id, path: "deleted.txt", action: "delete" }
    ])

    assert_equal "work", File.read(File.join(@master, "modified.txt"))
    assert_not File.exist?(File.join(@master, "deleted.txt"))
  end

  test "rejects path traversal during apply" do
    error = assert_raises(ArgumentError) do
      SandboxMountReconciler.new(@sandbox).apply!([
        { mount_id: @mount.id, path: "../escape", action: "delete" }
      ])
    end

    assert_match "Invalid path", error.message
  end

  test "committed added and deleted changes no longer block destroy" do
    File.write(File.join(@work, "added.txt"), "new")
    write_all("deleted.txt", "old")
    FileUtils.rm_f(File.join(@work, "deleted.txt"))

    reconciler = SandboxMountReconciler.new(@sandbox)
    assert reconciler.changed?

    reconciler.apply!([
      { mount_id: @mount.id, path: "added.txt", action: "use_work" },
      { mount_id: @mount.id, path: "deleted.txt", action: "delete" }
    ])

    assert_not SandboxMountReconciler.new(@sandbox).changed?
  end

  private

  def write_all(path, content)
    [ @base, @work, @master ].each do |root|
      FileUtils.mkdir_p(File.dirname(File.join(root, path)))
      File.write(File.join(root, path), content)
    end
  end
end
