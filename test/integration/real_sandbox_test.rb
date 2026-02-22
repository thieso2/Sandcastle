# frozen_string_literal: true

require "test_helper"
require "net/ssh"
require "timeout"

# Real Docker integration tests.
#
# These tests spin up actual Sysbox containers and verify the full lifecycle.
# They are skipped unless SANDCASTLE_REAL_DOCKER=1 is set.
#
# Prerequisites (run on sandman or a machine with Docker + Sysbox):
#   export SANDCASTLE_REAL_DOCKER=1
#   export SANDCASTLE_DATA_DIR=/tmp/sandcastle-test
#   export SANDCASTLE_TEST_IMAGE=sandcastle-sandbox-test:latest
#   export RAILS_ENV=test
#   bin/rails db:schema:load
#   bin/rails test test/integration/real_sandbox_test.rb
#
class RealSandboxTest < ActionDispatch::IntegrationTest
  REAL_DOCKER = ENV["SANDCASTLE_REAL_DOCKER"] == "1"
  TEST_IMAGE  = ENV.fetch("SANDCASTLE_TEST_IMAGE", "sandcastle-sandbox-test:latest")
  TEST_PREFIX = "sc-test-"

  # Allow no parallelism for Docker tests — each test must run serially to avoid
  # port collisions and network exhaustion.
  parallelize(workers: 1)

  setup do
    skip "Set SANDCASTLE_REAL_DOCKER=1 to run real Docker integration tests" unless REAL_DOCKER

    ENV["SANDCASTLE_DATA_DIR"] = "/tmp/sandcastle-test"
    FileUtils.mkdir_p("/tmp/sandcastle-test")

    @alice = users(:one)
    cleanup_test_containers
  end

  teardown do
    cleanup_test_containers if REAL_DOCKER
  end

  # -------------------------------------------------------------------------
  # Full sandbox lifecycle
  # -------------------------------------------------------------------------

  test "full sandbox lifecycle: create, start, stop, restart, destroy" do
    sandbox = build_test_sandbox("lifecycle")

    # create_container_and_start creates & starts the container
    manager = SandboxManager.new
    manager.create_container_and_start(sandbox: sandbox, user: @alice)
    sandbox.reload

    assert_equal "running", sandbox.status
    assert sandbox.container_id.present?

    # Verify container actually running in Docker
    container = Docker::Container.get(sandbox.container_id)
    assert container.json.dig("State", "Running"), "Container should be running in Docker"

    # Stop
    manager.stop(sandbox: sandbox)
    sandbox.reload
    assert_equal "stopped", sandbox.status

    c = Docker::Container.get(sandbox.container_id)
    assert_equal "exited", c.json.dig("State", "Status")

    # Start again
    manager.start(sandbox: sandbox)
    sandbox.reload
    assert_equal "running", sandbox.status

    c = Docker::Container.get(sandbox.container_id)
    assert c.json.dig("State", "Running")

    # Destroy
    manager.destroy(sandbox: sandbox)
    sandbox.reload
    assert_equal "destroyed", sandbox.status

    # Container should be gone
    assert_raises(Docker::Error::NotFoundError) { Docker::Container.get(sandbox.container_id) }
  end

  # -------------------------------------------------------------------------
  # Snapshot and restore
  # -------------------------------------------------------------------------

  test "snapshot and restore preserves data" do
    sandbox = build_test_sandbox("snaptest")
    manager = SandboxManager.new
    manager.create_container_and_start(sandbox: sandbox, user: @alice)

    # Wait for sshd to be available
    wait_for_ssh(sandbox)

    # Write a test file inside the container via docker exec
    container = Docker::Container.get(sandbox.container_id)
    container.exec([ "bash", "-c", "echo hello-snap > /test.txt" ])

    # Create snapshot
    snap = manager.create_snapshot(sandbox: sandbox, name: "snap-real-#{SecureRandom.hex(4)}")
    assert snap.docker_image.present?

    # Destroy original
    manager.destroy(sandbox: sandbox)

    # Restore into a new sandbox from the snapshot image
    sandbox2 = build_test_sandbox("snaptest2", image: snap.docker_image)
    manager.create_container_and_start(sandbox: sandbox2, user: @alice)

    container2 = Docker::Container.get(sandbox2.container_id)
    out, _err = container2.exec([ "cat", "/test.txt" ])
    assert_equal "hello-snap\n", out.join

    manager.destroy(sandbox: sandbox2)

    # Cleanup snapshot
    manager.destroy_snapshot(user: @alice, name: snap.name)
  end

  # -------------------------------------------------------------------------
  # SSH connectivity
  # -------------------------------------------------------------------------

  test "sandbox SSH connectivity" do
    # Generate a temporary keypair for this test
    key = OpenSSL::PKey::RSA.generate(2048)
    pub_key = "ssh-rsa #{[ key.public_key.to_der ].pack("m0")} test@sandcastle"

    sandbox = build_test_sandbox("sshtest", ssh_key: pub_key)
    manager = SandboxManager.new
    manager.create_container_and_start(sandbox: sandbox, user: @alice)

    # Wait for sshd to be ready
    ssh_port = wait_for_ssh(sandbox)

    # Connect via Net::SSH and run a command
    Net::SSH.start("localhost", @alice.name,
      keys: [],
      key_data: [ key.to_pem ],
      port: ssh_port,
      verify_host_key: :never,
      timeout: 10
    ) do |ssh|
      result = ssh.exec!("whoami").chomp
      assert_equal @alice.name, result
    end

    manager.destroy(sandbox: sandbox)
  end

  # -------------------------------------------------------------------------
  # Concurrent sandbox creation
  # -------------------------------------------------------------------------

  test "concurrent sandbox creation assigns unique SSH ports" do
    sandboxes = []
    manager = SandboxManager.new

    threads = 3.times.map do |i|
      Thread.new do
        sb = build_test_sandbox("concurrent#{i}")
        manager.create_container_and_start(sandbox: sb, user: @alice)
        sandboxes << sb
      end
    end
    threads.each(&:join)

    ports = sandboxes.map(&:ssh_port)
    assert_equal ports.uniq.size, ports.size, "All SSH ports must be unique: #{ports}"
    assert sandboxes.all? { |s| s.reload.status == "running" }

    sandboxes.each { |s| manager.destroy(sandbox: s) }
  end

  # -------------------------------------------------------------------------
  # Route Traefik config
  # -------------------------------------------------------------------------

  test "route creation writes Traefik config file" do
    sandbox = build_test_sandbox("routetest")
    manager = SandboxManager.new
    manager.create_container_and_start(sandbox: sandbox, user: @alice)

    Dir.mktmpdir do |dir|
      original_dynamic_dir = RouteManager::DYNAMIC_DIR
      RouteManager.send(:remove_const, :DYNAMIC_DIR)
      RouteManager.const_set(:DYNAMIC_DIR, dir)

      begin
        route_mgr = RouteManager.new
        route = route_mgr.add_route(sandbox: sandbox, domain: "test.example.com", port: 8080)

        config_path = File.join(dir, "sandbox-#{sandbox.id}.yml")
        assert File.exist?(config_path), "Traefik config should be written to #{config_path}"

        config = YAML.safe_load(File.read(config_path))
        assert config["http"]["routers"].any?
        assert config["http"]["services"].any?

        route_mgr.remove_route(route: route)
        assert_not File.exist?(config_path), "Traefik config should be removed after route deletion"
      ensure
        RouteManager.send(:remove_const, :DYNAMIC_DIR)
        RouteManager.const_set(:DYNAMIC_DIR, original_dynamic_dir)
      end
    end

    manager.destroy(sandbox: sandbox)
  end

  private

  def build_test_sandbox(suffix, image: TEST_IMAGE, ssh_key: nil)
    name = "#{TEST_PREFIX.delete_prefix("sc-")}#{suffix}"
    sandbox = @alice.sandboxes.create!(
      name: name,
      image: image,
      status: "pending",
      vnc_enabled: false,
      vnc_geometry: "1280x900",
      vnc_depth: 24
    )
    # inject SSH key via env if provided
    sandbox.instance_variable_set(:@_test_ssh_key, ssh_key) if ssh_key
    sandbox
  end

  # Poll until the SSH port is open (sshd started), max 30s.
  # Returns the port number.
  def wait_for_ssh(sandbox, timeout: 30)
    port = sandbox.reload.ssh_port
    Timeout.timeout(timeout) do
      loop do
        TCPSocket.new("localhost", port).close
        return port
      rescue Errno::ECONNREFUSED, Errno::ETIMEDOUT
        sleep 0.5
      end
    end
  rescue Timeout::Error
    raise "sshd on port #{sandbox.ssh_port} did not start within #{timeout}s"
  end

  # Remove any containers left over from previous test runs.
  def cleanup_test_containers
    Docker::Container.all(all: true).each do |c|
      name = c.json["Name"].to_s.delete_prefix("/")
      next unless name.start_with?(TEST_PREFIX) || name.start_with?("test-")

      c.delete(force: true)
    rescue Docker::Error::DockerError
      # already gone
    end

    # Also mark any test sandboxes in the DB as destroyed
    User.find_by(name: "alice")&.sandboxes
        &.where("name LIKE ?", "#{TEST_PREFIX.delete_prefix("sc-")}%")
        &.update_all(status: "destroyed")
  end
end
