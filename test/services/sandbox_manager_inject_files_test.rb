require "test_helper"

class SandboxManagerInjectFilesTest < ActiveSupport::TestCase
  setup do
    @manager = SandboxManager.new
    @user = users(:one)
    @sandbox = sandboxes(:alice_running)
    DockerMock.reset!
  end

  test "inject_files runs one exec per InjectedFile row" do
    @user.injected_files.create!(path: ".npmrc", content: "token=abc")
    @user.injected_files.create!(path: ".aws/credentials", content: "[default]\naws_access_key_id=AKIA")

    container = DockerMock.build(Docker::Container, "test-id", { "Id" => "test-id" })
    @manager.inject_files(container, @user)

    paths_written = DockerMock.exec_calls.map { |c| c[:cmd][5] }  # $2 = path arg
    assert_includes paths_written, ".npmrc"
    assert_includes paths_written, ".aws/credentials"
  end

  test "inject_files passes content via stdin-like arg, not env var" do
    secret = "SECRET-#{SecureRandom.hex(8)}"
    @user.injected_files.create!(path: ".secret", content: secret)

    container = DockerMock.build(Docker::Container, "test-id", { "Id" => "test-id" })
    @manager.inject_files(container, @user)

    call = DockerMock.exec_calls.first
    # The exec command should be ["bash", "-c", script, "_", username, path, content, mode]
    assert_equal "bash", call[:cmd][0]
    assert_equal "-c", call[:cmd][1]
    assert_equal @user.name, call[:cmd][4]
    assert_equal ".secret", call[:cmd][5]
    assert_equal secret, call[:cmd][6]
  end

  test "inject_files swallows Docker errors so one bad file doesn't kill the rest" do
    @user.injected_files.create!(path: ".one", content: "a")
    @user.injected_files.create!(path: ".two", content: "b")

    container = DockerMock.build(Docker::Container, "test-id", { "Id" => "test-id" })
    DockerMock.failure_mode = :exec

    assert_nothing_raised { @manager.inject_files(container, @user) }
  end

  test "write_home_baseline runs find > baseline.txt" do
    container = DockerMock.build(Docker::Container, "test-id", { "Id" => "test-id" })
    @manager.write_home_baseline(container, @user)

    call = DockerMock.exec_calls.first
    assert_includes call[:cmd][2], "find"
    assert_includes call[:cmd][2], SandboxManager::HOME_BASELINE_PATH
  end

  test "create_container_and_start invokes inject_files and write_home_baseline" do
    @sandbox.update!(container_id: nil, status: "pending")
    @user.injected_files.create!(path: ".test-credential", content: "data")

    @manager.create_container_and_start(sandbox: @sandbox, user: @user)

    cmds = DockerMock.exec_calls.map { |c| c[:cmd][2] }
    assert cmds.any? { |s| s.include?(".test-credential") || s.include?("printf") }, "inject_files should have run"
    assert cmds.any? { |s| s.include?(SandboxManager::HOME_BASELINE_PATH) }, "write_home_baseline should have run"
  end

  test "volume_binds includes per-user persisted paths when home is not mounted" do
    @user.persisted_paths.find_or_create_by!(path: ".claude")
    @user.persisted_paths.find_or_create_by!(path: ".codex")
    @sandbox.update!(mount_home: false)

    binds = @manager.send(:volume_binds, @user, @sandbox)
    assert binds.any? { |b| b.end_with?(":/home/#{@user.name}/.claude") }
    assert binds.any? { |b| b.end_with?(":/home/#{@user.name}/.codex") }
  end

  test "volume_binds skips persisted paths when full home is mounted" do
    @user.persisted_paths.find_or_create_by!(path: ".claude")
    @sandbox.update!(mount_home: true)

    binds = @manager.send(:volume_binds, @user, @sandbox)
    refute binds.any? { |b| b.end_with?(":/home/#{@user.name}/.claude") },
      "persisted paths should not be bound separately when full home is bound"
  end
end
