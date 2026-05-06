# frozen_string_literal: true

require "test_helper"

class SandboxProvisionJobTest < ActiveJob::TestCase
  setup do
    @data_dir = Dir.mktmpdir("sandcastle-provision-job-test-")
    @original_data_dirs = {
      SandboxManager => SandboxManager::DATA_DIR,
      BtrfsHelper => BtrfsHelper::DATA_DIR,
      SandboxMountBuilder => SandboxMountBuilder::DATA_DIR
    }
    @original_data_dirs.each { |klass, dir| replace_data_dir(klass, dir, @data_dir) }

    @user = users(:thies)
    @sandbox = @user.sandboxes.create!(
      name: "test-provision",
      image: "ghcr.io/thieso2/sandcastle-sandbox:latest"
    )
    DockerMock.reset!
  end

  teardown do
    @original_data_dirs&.each { |klass, dir| replace_data_dir(klass, klass::DATA_DIR, dir) }
    FileUtils.rm_rf(@data_dir) if @data_dir
  end

  test "successfully provisions sandbox" do
    assert_equal "pending", @sandbox.status

    perform_enqueued_jobs do
      SandboxProvisionJob.perform_later(sandbox_id: @sandbox.id)
    end

    @sandbox.reload
    assert_equal "running", @sandbox.status
    assert_not_nil @sandbox.container_id
    assert_nil @sandbox.job_error
  end

  test "handles provision failure" do
    DockerMock.inject_failure(:create)

    # The job catches the error, records it, then re-raises
    SandboxProvisionJob.perform_now(sandbox_id: @sandbox.id) rescue nil

    @sandbox.reload
    assert_equal "destroyed", @sandbox.status
    assert_not_nil @sandbox.job_error
    assert_includes @sandbox.job_error, "Failed to create"
  end

  test "is idempotent - skips if already running" do
    # Manually set status to running
    @sandbox.update!(status: "running", container_id: "existing_id")

    perform_enqueued_jobs do
      SandboxProvisionJob.perform_later(sandbox_id: @sandbox.id)
    end

    @sandbox.reload
    assert_equal "running", @sandbox.status
    assert_equal "existing_id", @sandbox.container_id
  end

  test "connects to Tailscale if enabled" do
    @sandbox.update!(tailscale: true)
    @user.update!(tailscale_state: "enabled")

    # Mock TailscaleManager to avoid real Docker network operations
    ts_connected = false
    ts_stub = Object.new
    ts_stub.define_singleton_method(:connect_sandbox) { |sandbox:| ts_connected = true }

    original_new = TailscaleManager.method(:new)
    TailscaleManager.define_singleton_method(:new) { ts_stub }

    begin
      perform_enqueued_jobs do
        SandboxProvisionJob.perform_later(sandbox_id: @sandbox.id)
      end
    ensure
      TailscaleManager.define_singleton_method(:new, original_new)
    end

    @sandbox.reload
    assert_equal "running", @sandbox.status
    assert ts_connected, "TailscaleManager#connect_sandbox should have been called"
  end

  private

  def replace_data_dir(klass, _current, replacement)
    klass.send(:remove_const, :DATA_DIR)
    klass.const_set(:DATA_DIR, replacement)
  end
end
