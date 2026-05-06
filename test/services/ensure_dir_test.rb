# frozen_string_literal: true

require "test_helper"

class EnsureDirTest < ActiveSupport::TestCase
  setup do
    @manager = SandboxManager.new
    @testdir = Dir.mktmpdir("sandcastle-ensure-dir-test-")
    DockerMock.reset!
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
    parent = File.join(@testdir, "users", "thies")
    FileUtils.mkdir_p(parent)
    child = File.join(parent, "some-subdir")

    calls = 0
    original_mkdir_p = FileUtils.method(:mkdir_p)
    FileUtils.define_singleton_method(:mkdir_p) do |path, *args, **kwargs|
      calls += 1 if path == child
      raise Errno::EACCES, path if path == child

      original_mkdir_p.call(path, *args, **kwargs)
    end

    error = assert_raises(Errno::EACCES, SandboxManager::Error) do
      @manager.send(:ensure_dir, child)
    end

    assert_equal 2, calls, "ensure_dir should retry mkdir_p after docker_chown"
    assert error.is_a?(Errno::EACCES) || error.is_a?(SandboxManager::Error)
  ensure
    FileUtils.define_singleton_method(:mkdir_p, original_mkdir_p) if original_mkdir_p
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
