# frozen_string_literal: true

require "test_helper"

class SandboxDestroyJobTest < ActiveJob::TestCase
  setup do
    @sandbox = sandboxes(:thies_dev)
    @manager = SandboxManager.new
    DockerMock.reset!

    # Create container for sandbox
    @manager.create_container_and_start(sandbox: @sandbox, user: @sandbox.user)
  end

  test "successfully destroys sandbox" do
    container_id = @sandbox.container_id
    assert_equal "running", @sandbox.status

    perform_enqueued_jobs do
      SandboxDestroyJob.perform_later(sandbox_id: @sandbox.id)
    end

    @sandbox.reload
    assert_equal "destroyed", @sandbox.status
    assert_nil @sandbox.job_error

    # Container should be deleted
    assert_raises(Docker::Error::NotFoundError) do
      Docker::Container.get(container_id)
    end
  end

  test "handles destroy failure" do
    DockerMock.inject_failure(:delete)

    assert_raises(Docker::Error::DockerError) do
      perform_enqueued_jobs do
        SandboxDestroyJob.perform_later(sandbox_id: @sandbox.id)
      end
    end

    @sandbox.reload
    assert_not_nil @sandbox.job_error
    assert_includes @sandbox.job_error, "Failed to destroy"
  end

  test "is idempotent - skips if already destroyed" do
    @sandbox.update!(status: "destroyed")

    perform_enqueued_jobs do
      SandboxDestroyJob.perform_later(sandbox_id: @sandbox.id)
    end

    @sandbox.reload
    assert_equal "destroyed", @sandbox.status
  end
end
