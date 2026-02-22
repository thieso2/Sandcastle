# frozen_string_literal: true

require "test_helper"

class SandboxManagerTest < ActiveSupport::TestCase
  setup do
    @manager = SandboxManager.new
    @user = users(:one)
    @sandbox = sandboxes(:alice_running)
    DockerMock.reset!
  end

  test "create_container_and_start creates and starts container" do
    @sandbox.update!(container_id: nil, status: "pending")

    @manager.create_container_and_start(sandbox: @sandbox, user: @user)

    @sandbox.reload
    assert_not_nil @sandbox.container_id
    assert_equal "running", @sandbox.status

    # Verify container exists in mock
    container = Docker::Container.get(@sandbox.container_id)
    assert_equal "running", container.info["State"]["Status"]
  end

  test "start starts a stopped container" do
    # Create container first
    @sandbox.update!(container_id: nil, status: "pending")
    @manager.create_container_and_start(sandbox: @sandbox, user: @user)
    container_id = @sandbox.container_id

    # Stop it
    @manager.stop(sandbox: @sandbox)
    assert_equal "stopped", @sandbox.reload.status

    # Start it again (start deletes the old container and creates a new one)
    @manager.start(sandbox: @sandbox)
    assert_equal "running", @sandbox.reload.status

    container = Docker::Container.get(@sandbox.container_id)
    assert container.info["State"]["Running"]
  end

  test "stop stops a running container" do
    @sandbox.update!(container_id: nil, status: "pending")
    @manager.create_container_and_start(sandbox: @sandbox, user: @user)
    assert_equal "running", @sandbox.reload.status

    @manager.stop(sandbox: @sandbox)
    assert_equal "stopped", @sandbox.reload.status

    container = Docker::Container.get(@sandbox.container_id)
    assert_not container.info["State"]["Running"]
  end

  test "destroy removes container and updates status" do
    @sandbox.update!(container_id: nil, status: "pending")
    @manager.create_container_and_start(sandbox: @sandbox, user: @user)
    container_id = @sandbox.container_id

    @manager.destroy(sandbox: @sandbox)

    assert_equal "destroyed", @sandbox.reload.status
    assert_raises(Docker::Error::NotFoundError) do
      Docker::Container.get(container_id)
    end
  end

  test "create handles Docker errors gracefully" do
    DockerMock.inject_failure(:create)

    # create_container_and_start doesn't wrap Docker errors; the high-level
    # SandboxManager#create does.  Test the public job-facing method directly.
    assert_raises(Docker::Error::DockerError) do
      @sandbox.update!(container_id: nil, status: "pending")
      @manager.create_container_and_start(sandbox: @sandbox, user: @user)
    end
  end

  test "ensure_image pulls image if not present" do
    image_name = "ghcr.io/thieso2/sandcastle-sandbox:latest"

    # Image should not exist initially
    assert_raises(Docker::Error::NotFoundError) do
      Docker::Image.get(image_name)
    end

    @manager.ensure_image(image_name)

    # Image should now exist
    image = Docker::Image.get(image_name)
    assert_not_nil image
  end

  test "create_snapshot creates DB record and Docker image" do
    @sandbox.update!(container_id: nil, status: "pending")
    @manager.create_container_and_start(sandbox: @sandbox, user: @user)
    @sandbox.reload

    snap = @manager.create_snapshot(sandbox: @sandbox, name: "test-snap")

    assert_kind_of Snapshot, snap
    assert_equal "test-snap", snap.name
    assert_equal @sandbox.name, snap.source_sandbox
    assert snap.docker_image.present?
    assert_includes snap.layers, "container"

    # Verify Docker image was committed
    Docker::Image.get(snap.docker_image)
  end

  test "create_snapshot with label stores label" do
    @sandbox.update!(container_id: nil, status: "pending")
    @manager.create_container_and_start(sandbox: @sandbox, user: @user)
    @sandbox.reload

    snap = @manager.create_snapshot(sandbox: @sandbox, name: "labeled-snap", label: "before migration")
    assert_equal "before migration", snap.label
  end

  test "create_snapshot with container-only layers" do
    @sandbox.update!(container_id: nil, status: "pending")
    @manager.create_container_and_start(sandbox: @sandbox, user: @user)
    @sandbox.reload

    snap = @manager.create_snapshot(sandbox: @sandbox, name: "container-only", layers: %w[container])
    assert_equal %w[container], snap.layers
    assert_nil snap.home_snapshot
    assert_nil snap.data_snapshot
  end

  test "list_snapshots returns DB records" do
    # Create a snapshot record
    Snapshot.create!(user: @user, name: "listed-snap", docker_image: "sc-snap-alice:listed-snap", docker_size: 100)

    snapshots = @manager.list_snapshots(user: @user)
    assert snapshots.any? { |s| s[:name] == "listed-snap" }
  end

  test "destroy_snapshot removes DB record and Docker image" do
    @sandbox.update!(container_id: nil, status: "pending")
    @manager.create_container_and_start(sandbox: @sandbox, user: @user)
    @sandbox.reload

    snap = @manager.create_snapshot(sandbox: @sandbox, name: "to-destroy")
    image_ref = snap.docker_image

    @manager.destroy_snapshot(user: @user, name: "to-destroy")

    assert_nil Snapshot.find_by(user: @user, name: "to-destroy")
    assert_raises(Docker::Error::NotFoundError) do
      Docker::Image.get(image_ref)
    end
  end

  test "destroy_snapshot raises error for non-existent snapshot" do
    assert_raises(SandboxManager::Error) do
      @manager.destroy_snapshot(user: @user, name: "nonexistent-snap")
    end
  end

  test "legacy snapshot method returns hash" do
    @sandbox.update!(container_id: nil, status: "pending")
    @manager.create_container_and_start(sandbox: @sandbox, user: @user)
    @sandbox.reload

    result = @manager.snapshot(sandbox: @sandbox, name: "legacy-test")

    assert_kind_of Hash, result
    assert_equal "legacy-test", result[:name]
    assert result[:image].present?
  end
end
