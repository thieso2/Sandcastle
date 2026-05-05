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

  test "create_container_and_start rotates and injects oidc runtime token when enabled" do
    ENV["SANDCASTLE_HOST"] = "test.sandcastle.example"
    @sandbox.update!(container_id: nil, status: "pending", oidc_enabled: true)

    @manager.create_container_and_start(sandbox: @sandbox, user: @user)

    @sandbox.reload
    assert @sandbox.oidc_secret_digest.present?
    assert @sandbox.oidc_secret_rotated_at.present?
    container = Docker::Container.get(@sandbox.container_id)
    assert_includes container.info.dig("Config", "Env"), "GOOGLE_EXTERNAL_ACCOUNT_ALLOW_EXECUTABLES=1"

    oidc_exec = DockerMock.exec_calls.find { |call| call[:cmd][2].to_s.include?("/run/sandcastle/oidc-token") }
    assert oidc_exec, "expected OIDC runtime injection"
    runtime_token = oidc_exec[:cmd][5]
    assert_equal @sandbox, Sandbox.authenticate_oidc_runtime_token(runtime_token)
  ensure
    ENV.delete("SANDCASTLE_HOST")
  end

  test "create_container_and_start injects transparent GCP credentials when configured" do
    ENV["SANDCASTLE_HOST"] = "test.sandcastle.example"
    config = @user.gcp_oidc_configs.create!(
      name: "test",
      project_id: "test-project-123",
      project_number: "123456789012",
      workload_identity_pool_id: "sandcastle",
      workload_identity_provider_id: "sandcastle",
      workload_identity_location: "global"
    )
    @sandbox.update!(
      container_id: nil,
      status: "pending",
      oidc_enabled: true,
      gcp_oidc_enabled: true,
      gcp_oidc_config: config,
      gcp_service_account_email: "sandbox@test-project-123.iam.gserviceaccount.com"
    )

    @manager.create_container_and_start(sandbox: @sandbox, user: @user)

    container = Docker::Container.get(@sandbox.container_id)
    env = container.info.dig("Config", "Env")
    assert_includes env, "GOOGLE_APPLICATION_CREDENTIALS=/etc/sandcastle/gcp-credentials.json"
    assert_includes env, "CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE=/etc/sandcastle/gcp-credentials.json"
    assert_includes env, "CLOUDSDK_CORE_PROJECT=test-project-123"
    assert_includes env, "GOOGLE_CLOUD_PROJECT=test-project-123"

    gcp_exec = DockerMock.exec_calls.find { |call| call[:cmd][2].to_s.include?("sandcastle-oidc gcp write-config") }
    assert gcp_exec, "expected GCP credential config injection"
    assert_includes gcp_exec[:cmd][2], "/etc/profile.d/sandcastle-oidc.sh"
    assert_includes gcp_exec[:cmd][2], "# >>> sandcastle oidc >>>"
    assert_equal "//iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/sandcastle/providers/sandcastle", gcp_exec[:cmd][11]
    assert_equal "sandbox@test-project-123.iam.gserviceaccount.com", gcp_exec[:cmd][12]
  ensure
    ENV.delete("SANDCASTLE_HOST")
  end

  test "create_container_and_start removes oidc runtime files when disabled" do
    @sandbox.update!(
      container_id: nil,
      status: "pending",
      oidc_enabled: false,
      oidc_secret_digest: BCrypt::Password.create("old"),
      oidc_secret_rotated_at: Time.current
    )

    @manager.create_container_and_start(sandbox: @sandbox, user: @user)

    @sandbox.reload
    assert_nil @sandbox.oidc_secret_digest
    assert_nil @sandbox.oidc_secret_rotated_at
    assert DockerMock.exec_calls.any? { |call| call[:cmd].join(" ").include?("rm -f /run/sandcastle/oidc-token") }
    assert DockerMock.exec_calls.any? { |call| call[:cmd].join(" ").include?("/etc/profile.d/sandcastle-oidc.sh") }
    assert DockerMock.exec_calls.any? { |call| call[:cmd].join(" ").include?("# >>> sandcastle oidc >>>") }
  end

  test "oidc runtime injection failure aborts oidc-enabled sandbox start" do
    ENV["SANDCASTLE_HOST"] = "test.sandcastle.example"
    @sandbox.update!(container_id: nil, status: "pending", oidc_enabled: true)
    DockerMock.failure_mode = :exec

    assert_raises(SandboxManager::Error) do
      @manager.create_container_and_start(sandbox: @sandbox, user: @user)
    end
    assert_equal "pending", @sandbox.reload.status
    assert_nil @sandbox.container_id
    assert_nil @sandbox.oidc_secret_digest
  ensure
    ENV.delete("SANDCASTLE_HOST")
  end

  test "start rotates oidc runtime token and invalidates previous token" do
    ENV["SANDCASTLE_HOST"] = "test.sandcastle.example"
    @sandbox.update!(container_id: nil, status: "pending", oidc_enabled: true)
    @manager.create_container_and_start(sandbox: @sandbox, user: @user)
    first_token = DockerMock.exec_calls.find { |call| call[:cmd][2].to_s.include?("/run/sandcastle/oidc-token") }[:cmd][5]

    @manager.stop(sandbox: @sandbox)
    DockerMock.exec_calls.clear
    @manager.start(sandbox: @sandbox)
    second_token = DockerMock.exec_calls.find { |call| call[:cmd][2].to_s.include?("/run/sandcastle/oidc-token") }[:cmd][5]

    assert_not_equal first_token, second_token
    assert_nil Sandbox.authenticate_oidc_runtime_token(first_token)
    assert_equal @sandbox.reload, Sandbox.authenticate_oidc_runtime_token(second_token)
  ensure
    ENV.delete("SANDCASTLE_HOST")
  end

  test "start starts a stopped container" do
    # Create container first
    @sandbox.update!(container_id: nil, status: "pending")
    @manager.create_container_and_start(sandbox: @sandbox, user: @user)
    container_id = @sandbox.container_id

    # Stop it
    @manager.stop(sandbox: @sandbox)
    assert_equal "stopped", @sandbox.reload.status

    # Start it again (creates a new container)
    @manager.start(sandbox: @sandbox)
    @sandbox.reload
    assert_equal "running", @sandbox.status

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

  # Regression test: bind-mounted dirs must be reset to 777 on restart.
  # After a Sysbox container run, dirs are re-owned by the Sysbox-remapped UID
  # (e.g. 166537) so the Rails process can't chmod them without sudo.
  test "start calls ensure_mount_dirs for sandboxes with mount_home to reset bind-mount permissions" do
    @sandbox.update!(mount_home: true, status: "stopped", container_id: nil)

    ensure_called = false
    manager = Class.new(SandboxManager) {
      define_method(:ensure_mount_dirs) { |_user, _sandbox| ensure_called = true }
    }.new
    manager.start(sandbox: @sandbox)

    assert ensure_called,
      "SandboxManager#start must call ensure_mount_dirs before creating the container " \
      "so the home dir is reset to 777; without this, Sysbox UID remapping leaves the " \
      "dir owned by nobody (chmod 755) and breaks SSH StrictModes and VNC ~/.Xauthority"
  end

  test "start calls ensure_mount_dirs for sandboxes with data_path to reset bind-mount permissions" do
    @sandbox.update!(data_path: "mydata", status: "stopped", container_id: nil)

    ensure_called = false
    manager = Class.new(SandboxManager) {
      define_method(:ensure_mount_dirs) { |_user, _sandbox| ensure_called = true }
    }.new
    manager.start(sandbox: @sandbox)

    assert ensure_called,
      "SandboxManager#start must call ensure_mount_dirs for data_path sandboxes too"
  end

  test "start calls ensure_mount_dirs for sandboxes with home_path to reset bind-mount permissions" do
    @sandbox.update!(home_path: "projects/demo", mount_home: false, status: "stopped", container_id: nil)

    ensure_called = false
    manager = Class.new(SandboxManager) {
      define_method(:ensure_mount_dirs) { |_user, _sandbox| ensure_called = true }
    }.new
    manager.start(sandbox: @sandbox)

    assert ensure_called,
      "SandboxManager#start must call ensure_mount_dirs for home_path sandboxes too"
  end

  test "sync_mount_records records direct home and data mounts" do
    @sandbox.update!(mount_home: true, data_path: "projects/app")

    @manager.send(:sync_mount_records, @user, @sandbox)

    mounts = @sandbox.sandbox_mounts.order(:target_path).to_a
    assert_equal 2, mounts.size

    data = mounts.find { |m| m.mount_type == "data" }
    assert_equal "direct", data.storage_mode
    assert_equal "projects/app", data.logical_path
    assert_equal "/persisted", data.target_path
    assert_equal "#{SandboxManager::DATA_DIR}/users/#{@user.name}/data/projects/app", data.master_path
    assert_equal data.master_path, data.source_path

    home = mounts.find { |m| m.mount_type == "home" }
    assert_equal "/home/#{@user.name}", home.target_path
    assert_equal "#{SandboxManager::DATA_DIR}/users/#{@user.name}/home", home.source_path
  end

  test "sync_mount_records records persisted paths when home is not mounted" do
    path = ".tool-#{SecureRandom.hex(4)}"
    @user.persisted_paths.create!(path: path)
    @sandbox.update!(mount_home: false, data_path: nil)

    @manager.send(:sync_mount_records, @user, @sandbox)

    mount = @sandbox.sandbox_mounts.find_by!(logical_path: path)
    assert_equal "persisted_path", mount.mount_type
    assert_equal "/home/#{@user.name}/#{path}", mount.target_path
    assert_equal "#{SandboxManager::DATA_DIR}/users/#{@user.name}/persisted/#{path}", mount.source_path
  end

  test "volume_binds uses sandbox mount records when present" do
    @sandbox.sandbox_mounts.create!(
      mount_type: "home",
      target_path: "/home/#{@user.name}",
      master_path: "/data/users/#{@user.name}/home",
      source_path: "/data/reconcile/#{@sandbox.id}/work/home"
    )

    binds = @manager.send(:volume_binds, @user, @sandbox)

    assert_equal [ "/data/reconcile/#{@sandbox.id}/work/home:/home/#{@user.name}" ], binds
  end
end
