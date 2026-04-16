require "test_helper"

class HomeFileDiscoveryTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
    @sandbox = sandboxes(:alice_running)
    DockerMock.reset!

    # Pre-create container record in the mock so Docker::Container.get(...) works
    DockerMock.containers[@sandbox.container_id] = {
      "Id" => @sandbox.container_id,
      "State" => { "Status" => "running", "Running" => true }
    }
  end

  test "returns empty when sandbox has no container" do
    @sandbox.update!(container_id: nil)
    assert_equal [], HomeFileDiscovery.new(@sandbox).call
  end

  test "filters out exact-ignore paths" do
    DockerMock.exec_response = [ [ ".bash_history\n.something-real\n" ], [], 0 ]
    results = HomeFileDiscovery.new(@sandbox).call
    paths = results.map { |r| r[:path] }
    assert_includes paths, ".something-real"
    assert_not_includes paths, ".bash_history"
  end

  test "filters out prefix-ignore paths" do
    DockerMock.exec_response = [ [ ".cache/foo/bar\n.local/share/Trash/x\n.real-file\n" ], [], 0 ]
    paths = HomeFileDiscovery.new(@sandbox).call.map { |r| r[:path] }
    assert_equal [ ".real-file" ], paths
  end

  test "filters per-user IgnoredPath entries" do
    @user.ignored_paths.create!(path: ".user-ignored")
    DockerMock.exec_response = [ [ ".user-ignored\n.kept\n" ], [], 0 ]
    paths = HomeFileDiscovery.new(@sandbox).call.map { |r| r[:path] }
    assert_equal [ ".kept" ], paths
  end

  test "suggests bind for known OAuth dirs" do
    DockerMock.exec_response = [ [ ".claude/.credentials.json\n" ], [], 0 ]
    row = HomeFileDiscovery.new(@sandbox).call.first
    assert_equal "bind", row[:suggested]
  end

  test "suggests inject for known static config files" do
    DockerMock.exec_response = [ [ ".npmrc\n" ], [], 0 ]
    row = HomeFileDiscovery.new(@sandbox).call.first
    assert_equal "inject", row[:suggested]
  end

  test "suggests ignore for unrecognized files" do
    DockerMock.exec_response = [ [ ".some-novel-file\n" ], [], 0 ]
    row = HomeFileDiscovery.new(@sandbox).call.first
    assert_equal "ignore", row[:suggested]
  end

  test "fetch_content runs cat in container" do
    DockerMock.exec_response = ->(_cmd) { [ [ "file body here" ], [], 0 ] }
    content = HomeFileDiscovery.new(@sandbox).fetch_content(".claude/.credentials.json")
    assert_equal "file body here", content
    last = DockerMock.exec_calls.last
    assert_match(/\Acat /, last[:cmd][2])
  end

  test "discovery exec uses the baseline path constant" do
    DockerMock.exec_response = [ [ "" ], [], 0 ]
    HomeFileDiscovery.new(@sandbox).call
    last = DockerMock.exec_calls.last
    assert_includes last[:cmd][2], SandboxManager::HOME_BASELINE_PATH
  end
end
