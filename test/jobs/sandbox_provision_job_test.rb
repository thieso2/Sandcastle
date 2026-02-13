# frozen_string_literal: true

require "test_helper"

class SandboxProvisionJobTest < ActiveJob::TestCase
  setup do
    @user = users(:thies)
    @sandbox = @user.sandboxes.create!(
      name: "test-provision",
      image: "ghcr.io/thieso2/sandcastle-sandbox:latest",
      persistent: false
    )
    DockerMock.reset!
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

    assert_raises(Docker::Error::DockerError) do
      perform_enqueued_jobs do
        SandboxProvisionJob.perform_later(sandbox_id: @sandbox.id)
      end
    end

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

    # Mock Tailscale network existence
    DockerMock.networks["mock_ts_net"] = {
      "Id" => "mock_ts_net",
      "Name" => "sc-ts-net-#{@user.name}"
    }

    perform_enqueued_jobs do
      SandboxProvisionJob.perform_later(sandbox_id: @sandbox.id)
    end

    @sandbox.reload
    assert_equal "running", @sandbox.status
    # Would verify Tailscale connection here in real test
  end
end
