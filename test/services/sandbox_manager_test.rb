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

    # Start it again
    @manager.start(sandbox: @sandbox)
    assert_equal "running", @sandbox.reload.status

    container = Docker::Container.get(container_id)
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

    assert_raises(SandboxManager::Error) do
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

  # Regression test for: SSH and VNC broken when user home is mounted (issue #68)
  #
  # Root cause: Sysbox user-namespace UID remapping means the bind-mounted home
  # dir (created by host root) appears owned by nobody (UID 65534) inside the
  # container. The entrypoint's `chown -R` fails silently, leaving the dir with
  # wrong ownership. Without ensure_mount_dirs being called on restart, the dir
  # can be left at chmod 755 from the previous container run, making it
  # unwritable by the sandbox user → SSH StrictModes rejects keys, VNC can't
  # create ~/.Xauthority.
  test "start calls ensure_mount_dirs for sandboxes with mount_home to reset bind-mount permissions" do
    @sandbox.update!(mount_home: true, status: "stopped", container_id: nil)

    ensure_called = false
    @manager.stub(:ensure_mount_dirs, ->(_user, _sandbox) { ensure_called = true }) do
      @manager.start(sandbox: @sandbox)
    end

    assert ensure_called,
      "SandboxManager#start must call ensure_mount_dirs before creating the container " \
      "so the home dir is reset to 777; without this, Sysbox UID remapping leaves the " \
      "dir owned by nobody (chmod 755) and breaks SSH StrictModes and VNC ~/.Xauthority"
  end

  test "start calls ensure_mount_dirs for sandboxes with data_path to reset bind-mount permissions" do
    @sandbox.update!(data_path: "mydata", status: "stopped", container_id: nil)

    ensure_called = false
    @manager.stub(:ensure_mount_dirs, ->(_user, _sandbox) { ensure_called = true }) do
      @manager.start(sandbox: @sandbox)
    end

    assert ensure_called,
      "SandboxManager#start must call ensure_mount_dirs for data_path sandboxes too"
  end
end
