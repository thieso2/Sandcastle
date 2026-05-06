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

    # The job catches the error, records it, then re-raises
    SandboxDestroyJob.perform_now(sandbox_id: @sandbox.id) rescue nil

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

  test "is idempotent - skips if already archived" do
    @sandbox.update!(status: "archived", archived_at: Time.current)

    perform_enqueued_jobs do
      SandboxDestroyJob.perform_later(sandbox_id: @sandbox.id, archive: true)
    end

    @sandbox.reload
    assert_equal "archived", @sandbox.status
  end
end
