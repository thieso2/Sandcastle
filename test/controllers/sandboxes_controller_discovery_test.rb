require "test_helper"

class SandboxesControllerDiscoveryTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @sandbox = sandboxes(:alice_running)
    sign_in_as(@user)
    DockerMock.reset!
    DockerMock.containers[@sandbox.container_id] = {
      "Id" => @sandbox.container_id,
      "State" => { "Status" => "running", "Running" => true }
    }
  end

  test "GET discover_files returns the rendered table" do
    DockerMock.exec_response = [ [ ".claude/.credentials.json\n.npmrc\n" ], [], 0 ]
    get discover_files_sandbox_path(@sandbox)
    assert_response :success
    assert_select "td", text: /\.claude\/\.credentials\.json/
    assert_select "td", text: /\.npmrc/
  end

  test "POST promote_file with action_type=bind creates a PersistedPath for the parent dir" do
    post promote_file_sandbox_path(@sandbox), params: {
      path: ".claude/.credentials.json", action_type: "bind"
    }
    assert_redirected_to sandbox_path(@sandbox, anchor: "discover")
    assert_not_nil @user.persisted_paths.find_by(path: ".claude")
  end

  test "POST promote_file with action_type=bind on top-level file uses path as bind dir" do
    post promote_file_sandbox_path(@sandbox), params: {
      path: ".somedir", action_type: "bind"
    }
    assert_not_nil @user.persisted_paths.find_by(path: ".somedir")
  end

  test "POST promote_file with action_type=inject reads content via exec and stores it" do
    DockerMock.exec_response = ->(_cmd) { [ [ "FILE BODY" ], [], 0 ] }
    post promote_file_sandbox_path(@sandbox), params: {
      path: ".npmrc", action_type: "inject"
    }
    inj = @user.injected_files.find_by!(path: ".npmrc")
    assert_equal "FILE BODY", inj.content
  end

  test "POST promote_file with action_type=ignore creates an IgnoredPath" do
    post promote_file_sandbox_path(@sandbox), params: {
      path: ".weird/file", action_type: "ignore"
    }
    assert_not_nil @user.ignored_paths.find_by(path: ".weird/file")
  end

  test "POST promote_file with unknown action returns alert" do
    post promote_file_sandbox_path(@sandbox), params: {
      path: ".x", action_type: "haxx"
    }
    assert_match(/Unknown action/, flash[:alert].to_s)
  end

  test "POST promote_file blocks foreign sandbox" do
    other = sandboxes(:bob_running)
    post promote_file_sandbox_path(other), params: { path: ".x", action_type: "ignore" }
    # set_sandbox uses policy_scope which excludes other users' sandboxes,
    # so find raises ActiveRecord::RecordNotFound → rendered as 404 in test env.
    assert_response :not_found
    assert_nil @user.ignored_paths.find_by(path: ".x")
  end
end
