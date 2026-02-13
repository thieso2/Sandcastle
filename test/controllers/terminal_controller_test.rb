require "test_helper"

class TerminalControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:one) # alice, admin
    @user = users(:two) # bob, non-admin
    @alice_sandbox = sandboxes(:alice_running)
    @bob_sandbox = sandboxes(:bob_running)
    @stopped_sandbox = sandboxes(:alice_stopped)
  end

  # ── auth (forwardAuth endpoint) ────────────────────────────────

  test "auth returns 401 without X-Forwarded-Uri" do
    get terminal_auth_path
    assert_response :unauthorized
  end

  test "auth returns 401 with malformed X-Forwarded-Uri" do
    get terminal_auth_path, headers: { "X-Forwarded-Uri" => "/some/random/path" }
    assert_response :unauthorized
  end

  test "auth redirects to login without session cookie" do
    get terminal_auth_path, headers: {
      "X-Forwarded-Uri" => "/terminal/#{@alice_sandbox.id}/wetty/",
      "X-Forwarded-Proto" => "https",
      "X-Forwarded-Host" => "sandbox.example.com"
    }
    assert_response :redirect
    assert_redirected_to new_session_url
  end

  test "auth stores return_to URL from forwarded headers" do
    get terminal_auth_path, headers: {
      "X-Forwarded-Uri" => "/terminal/#{@alice_sandbox.id}/wetty/",
      "X-Forwarded-Proto" => "https",
      "X-Forwarded-Host" => "sandbox.example.com"
    }
    assert_equal "https://sandbox.example.com/terminal/#{@alice_sandbox.id}/wetty/",
                 session[:return_to_after_authenticating]
  end

  test "auth returns 200 for sandbox owner" do
    sign_in_as(@admin) # alice owns alice_sandbox
    get terminal_auth_path, headers: { "X-Forwarded-Uri" => "/terminal/#{@alice_sandbox.id}/wetty/" }
    assert_response :ok
  end

  test "auth returns 401 for non-owner" do
    sign_in_as(@user) # bob does NOT own alice_sandbox
    get terminal_auth_path, headers: { "X-Forwarded-Uri" => "/terminal/#{@alice_sandbox.id}/wetty/" }
    assert_response :unauthorized
  end

  test "auth returns 200 for admin accessing another user's sandbox" do
    sign_in_as(@admin)
    get terminal_auth_path, headers: { "X-Forwarded-Uri" => "/terminal/#{@bob_sandbox.id}/wetty/" }
    assert_response :ok
  end

  test "auth returns 401 for non-existent sandbox ID" do
    sign_in_as(@admin)
    get terminal_auth_path, headers: { "X-Forwarded-Uri" => "/terminal/999999/wetty/" }
    assert_response :unauthorized
  end

  test "auth returns 401 for destroyed sandbox" do
    destroyed = sandboxes(:alice_destroyed)
    sign_in_as(@admin)
    get terminal_auth_path, headers: { "X-Forwarded-Uri" => "/terminal/#{destroyed.id}/wetty/" }
    assert_response :unauthorized
  end

  test "auth handles nested wetty paths" do
    sign_in_as(@admin)
    get terminal_auth_path, headers: { "X-Forwarded-Uri" => "/terminal/#{@alice_sandbox.id}/wetty/socket.io/?transport=websocket" }
    assert_response :ok
  end

  test "auth returns 401 for path traversal attempt" do
    sign_in_as(@admin)
    get terminal_auth_path, headers: { "X-Forwarded-Uri" => "/terminal/../admin" }
    assert_response :unauthorized
  end

  test "auth returns 200 for bob accessing his own sandbox" do
    sign_in_as(@user)
    get terminal_auth_path, headers: { "X-Forwarded-Uri" => "/terminal/#{@bob_sandbox.id}/wetty/" }
    assert_response :ok
  end

  # ── open ───────────────────────────────────────────────────────

  test "open requires authentication" do
    post terminal_sandbox_path(@alice_sandbox)
    assert_redirected_to new_session_path
  end

  test "open redirects to WeTTY URL on success" do
    sign_in_as(@admin)
    url = "/terminal/#{@alice_sandbox.id}/wetty"

    with_terminal_manager_stub(open_result: url) do
      post terminal_sandbox_path(@alice_sandbox)
    end

    assert_response :see_other
    assert_redirected_to url
  end

  test "open returns 404 for another user's sandbox" do
    sign_in_as(@user) # bob cannot access alice's sandbox
    post terminal_sandbox_path(@alice_sandbox)
    assert_response :not_found
  end

  test "admin can open terminal for any sandbox" do
    sign_in_as(@admin)

    with_terminal_manager_stub(open_result: "/terminal/#{@bob_sandbox.id}/wetty") do
      post terminal_sandbox_path(@bob_sandbox)
    end

    assert_response :see_other
  end

  test "open redirects to root with alert on TerminalManager error" do
    sign_in_as(@admin)

    with_terminal_manager_stub(open_error: "Sandbox is not running") do
      post terminal_sandbox_path(@alice_sandbox)
    end

    assert_redirected_to root_path
    assert_equal "Sandbox is not running", flash[:alert]
  end

  # ── close ──────────────────────────────────────────────────────

  test "close requires authentication" do
    delete terminal_sandbox_path(@alice_sandbox)
    assert_redirected_to new_session_path
  end

  test "close redirects to root with notice on success" do
    sign_in_as(@admin)

    with_terminal_manager_stub do
      delete terminal_sandbox_path(@alice_sandbox)
    end

    assert_redirected_to root_path
    assert_equal "Terminal closed", flash[:notice]
  end

  test "close returns 404 for another user's sandbox" do
    sign_in_as(@user)
    delete terminal_sandbox_path(@alice_sandbox)
    assert_response :not_found
  end

  test "admin can close terminal for any sandbox" do
    sign_in_as(@admin)

    with_terminal_manager_stub do
      delete terminal_sandbox_path(@bob_sandbox)
    end

    assert_redirected_to root_path
  end

  test "close redirects to root with alert on TerminalManager error" do
    sign_in_as(@admin)

    with_terminal_manager_stub(close_error: "Close failed") do
      delete terminal_sandbox_path(@alice_sandbox)
    end

    assert_redirected_to root_path
    assert_equal "Close failed", flash[:alert]
  end

  private

  def with_terminal_manager_stub(open_result: nil, open_error: nil, close_error: nil, &block)
    stub = Object.new
    stub.define_singleton_method(:open) do |sandbox:|
      raise TerminalManager::Error, open_error if open_error
      open_result
    end
    stub.define_singleton_method(:close) do |sandbox:|
      raise TerminalManager::Error, close_error if close_error
    end

    original_new = TerminalManager.method(:new)
    TerminalManager.define_singleton_method(:new) { stub }
    begin
      yield
    ensure
      TerminalManager.define_singleton_method(:new, original_new)
    end
  end
end
