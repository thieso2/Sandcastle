# frozen_string_literal: true

require "test_helper"

class SandboxManagerTest < ActiveSupport::TestCase
  setup do
    @manager = SandboxManager.new
    @user = users(:thies)
    @sandbox = sandboxes(:thies_dev)
    DockerMock.reset!
  end

  test "create_container_and_start creates and starts container" do
    assert_nil @sandbox.container_id

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
    @manager.create_container_and_start(sandbox: @sandbox, user: @user)
    assert_equal "running", @sandbox.reload.status

    @manager.stop(sandbox: @sandbox)
    assert_equal "stopped", @sandbox.reload.status

    container = Docker::Container.get(@sandbox.container_id)
    assert_not container.info["State"]["Running"]
  end

  test "destroy removes container and updates status" do
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

  test "snapshot creates image from container" do
    @manager.create_container_and_start(sandbox: @sandbox, user: @user)

    snapshot_name = "#{@user.name}/#{@sandbox.name}:snapshot1"
    image = @manager.snapshot(sandbox: @sandbox, tag: snapshot_name)

    assert_not_nil image
    assert_includes image.info["RepoTags"], snapshot_name
  end
end
