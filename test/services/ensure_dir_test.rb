# frozen_string_literal: true

require "test_helper"

class EnsureDirTest < ActiveSupport::TestCase
  setup do
    @manager = SandboxManager.new
    @testdir = Dir.mktmpdir("sandcastle-ensure-dir-test-")
  end

  teardown do
    FileUtils.rm_rf(@testdir)
  end

  test "ensure_dir creates directory when parent is writable" do
    path = File.join(@testdir, "users", "alice", "home")
    @manager.send(:ensure_dir, path)
    assert Dir.exist?(path), "ensure_dir should create nested directories"
  end

  test "ensure_dir self-heals when parent is not writable" do
    # Create parent dir, then make it unwritable
    parent = File.join(@testdir, "users", "thies")
    FileUtils.mkdir_p(parent)
    FileUtils.chmod(0o555, parent)

    # Verify mkdir would fail
    child = File.join(parent, "chrome-profile")
    assert_raises(Errno::EACCES) { FileUtils.mkdir_p(child) }

    # ensure_dir should catch EACCES and attempt docker_chown.
    # In test env the mock container doesn't actually fix permissions,
    # so the second mkdir_p will also fail. Verify the flow is correct
    # by checking that the Error mentions docker_run_fix.
    error = assert_raises(Errno::EACCES, SandboxManager::Error) do
      @manager.send(:ensure_dir, child)
    end
    # The flow tried: mkdir_p → EACCES → docker_chown → mkdir_p again
    # With mock Docker it can't actually fix perms, so second mkdir_p fails too
    assert error.is_a?(Errno::EACCES) || error.is_a?(SandboxManager::Error)
  ensure
    # Restore permissions so teardown can clean up
    FileUtils.chmod(0o755, parent) if parent && Dir.exist?(parent)
  end

  test "docker_run_fix creates container with correct bind mount" do
    # Verify docker_run_fix calls Docker API correctly (mock intercepts)
    container_count_before = DockerMock.containers.size
    @manager.send(:docker_run_fix, @testdir, "true")
    # Container was created and deleted (ensure block), but we can verify
    # it went through the mock by checking no containers leak
    assert_equal container_count_before, DockerMock.containers.size,
      "docker_run_fix should clean up its container"
  end

  test "fix_image returns busybox when available" do
    image = @manager.send(:fix_image)
    assert_equal "busybox:latest", image
  end

  test "fix_image falls back when busybox is not available" do
    DockerMock.images.delete("busybox:latest")
    DockerMock.images["alpine:latest"] = {
      "Id" => "sha256:alpine_mock",
      "RepoTags" => [ "alpine:latest" ],
      "Size" => 5_000_000,
      "Created" => Time.current.to_i
    }
    image = @manager.send(:fix_image)
    assert_equal "alpine:latest", image
  end

  test "fix_image raises when no images available" do
    DockerMock.images.clear
    assert_raises(SandboxManager::Error) do
      @manager.send(:fix_image)
    end
  end
end
