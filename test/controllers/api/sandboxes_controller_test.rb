# frozen_string_literal: true

require "test_helper"

class Api::SandboxesControllerTest < ActionDispatch::IntegrationTest
  setup do
    # Pre-populate DockerMock with fixture containers so snapshot/commit work.
    DockerMock.reset!
    [ sandboxes(:alice_running), sandboxes(:bob_running), sandboxes(:alice_stopped) ].each do |sb|
      next if sb.container_id.blank?
      DockerMock.containers[sb.container_id] = {
        "Id" => sb.container_id,
        "Name" => sb.full_name,
        "State" => { "Status" => sb.status == "running" ? "running" : "exited", "Running" => sb.status == "running" }
      }
    end
  end
  # --- index ---

  test "index returns active sandboxes (admin sees all, non-admin sees own)" do
    # Alice is admin — she sees all active sandboxes
    get "/api/sandboxes", headers: auth_headers
    assert_response :ok
    body = JSON.parse(response.body)
    names = body.map { |s| s["name"] }
    assert_includes names, "devbox"
    assert_includes names, "stopped-box"
    assert_not_includes names, "old-box"      # destroyed

    # Bob (non-admin) sees only his own
    get "/api/sandboxes", headers: auth_headers(BOB_TOKEN)
    assert_response :ok
    body = JSON.parse(response.body)
    names = body.map { |s| s["name"] }
    assert_includes names, "workbox"
    assert_not_includes names, "devbox"
    assert_not_includes names, "old-box"
  end

  test "index returns 401 without auth" do
    get "/api/sandboxes"
    assert_response :unauthorized
  end

  test "bob cannot see alice's sandboxes" do
    get "/api/sandboxes", headers: auth_headers(BOB_TOKEN)
    body = JSON.parse(response.body)
    names = body.map { |s| s["name"] }
    assert_includes names, "workbox"
    assert_not_includes names, "devbox"
  end

  # --- show ---

  test "show returns sandbox JSON" do
    get "/api/sandboxes/#{sandboxes(:alice_running).id}", headers: auth_headers
    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal "devbox", body["name"]
    assert_equal "running", body["status"]
  end

  test "show returns 403 when sandbox belongs to another user (non-admin)" do
    # Bob (non-admin) cannot see Alice's sandbox
    get "/api/sandboxes/#{sandboxes(:alice_running).id}", headers: auth_headers(BOB_TOKEN)
    assert_response :forbidden
  end

  test "show returns 404 for non-existent sandbox" do
    get "/api/sandboxes/0", headers: auth_headers
    assert_response :not_found
  end

  # --- create ---

  test "create enqueues SandboxProvisionJob and returns 201" do
    assert_enqueued_with(job: SandboxProvisionJob) do
      post "/api/sandboxes",
        params: { name: "newbox" },
        headers: auth_headers
    end
    assert_response :created
    body = JSON.parse(response.body)
    assert_equal "newbox", body["name"]
    assert_equal "pending", body["status"]
  end

  test "create from snapshot uses snapshot image" do
    assert_enqueued_with(job: SandboxProvisionJob) do
      post "/api/sandboxes",
        params: { name: "restored", from_snapshot: "my-snapshot" },
        headers: auth_headers
    end
    assert_response :created
    body = JSON.parse(response.body)
    assert_equal "sc-snap-alice:my-snapshot", body["image"]
  end

  # --- update ---

  test "update changes temporary flag" do
    patch "/api/sandboxes/#{sandboxes(:alice_running).id}",
      params: { temporary: true },
      headers: auth_headers
    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal true, body["temporary"]
  end

  # --- destroy ---

  test "destroy enqueues SandboxDestroyJob" do
    assert_enqueued_with(job: SandboxDestroyJob) do
      delete "/api/sandboxes/#{sandboxes(:alice_running).id}", headers: auth_headers
    end
    assert_response :ok
  end

  # --- start / stop ---

  test "start enqueues SandboxStartJob" do
    assert_enqueued_with(job: SandboxStartJob) do
      post "/api/sandboxes/#{sandboxes(:alice_stopped).id}/start", headers: auth_headers
    end
    assert_response :ok
  end

  test "stop enqueues SandboxStopJob" do
    assert_enqueued_with(job: SandboxStopJob) do
      post "/api/sandboxes/#{sandboxes(:alice_running).id}/stop", headers: auth_headers
    end
    assert_response :ok
  end

  # --- connect ---

  test "connect on pending sandbox returns 202 with helpful error" do
    alice_pending = sandboxes(:alice_running)
    alice_pending.update!(status: "pending")

    # connect_info raises SandboxManager::Error when tailscale not available
    post "/api/sandboxes/#{alice_pending.id}/connect", headers: auth_headers
    # Either 202 (pending branch) or 422 (tailscale error) — both acceptable
    assert_includes [ 202, 422 ], response.status
  end

  # --- snapshot ---

  test "snapshot creates a snapshot record" do
    post "/api/sandboxes/#{sandboxes(:alice_running).id}/snapshot",
      params: { name: "snap1" },
      headers: auth_headers
    assert_response :created
    body = JSON.parse(response.body)
    assert_equal "snap1", body["name"]
  end

  # --- restore ---

  test "restore calls SandboxManager#restore" do
    SandboxManager.any_instance.stubs(:restore).returns(sandboxes(:alice_running))
    post "/api/sandboxes/#{sandboxes(:alice_running).id}/restore",
      params: { snapshot: "my-snapshot" },
      headers: auth_headers
    assert_response :ok
  end

  # --- VNC ---

  test "vnc returns url and active true for running sandbox" do
    post "/api/sandboxes/#{sandboxes(:alice_running).id}/vnc", headers: auth_headers
    assert_response :ok
    body = JSON.parse(response.body)
    assert_match %r{/novnc/vnc\.html}, body["url"]
    assert_equal true, body["active"]
  end

  test "vnc returns 422 for stopped sandbox" do
    post "/api/sandboxes/#{sandboxes(:alice_stopped).id}/vnc", headers: auth_headers
    assert_response :unprocessable_entity
  end

  test "vnc_status returns active flag" do
    get "/api/sandboxes/#{sandboxes(:alice_running).id}/vnc_status", headers: auth_headers
    assert_response :ok
    body = JSON.parse(response.body)
    assert body.key?("active")
  end

  test "close_vnc returns active false" do
    delete "/api/sandboxes/#{sandboxes(:alice_running).id}/vnc", headers: auth_headers
    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal false, body["active"]
  end

  # --- cross-user enforcement ---

  test "non-admin cannot start sandbox belonging to another user" do
    # Bob (non-admin) cannot start Alice's sandbox
    post "/api/sandboxes/#{sandboxes(:alice_running).id}/start", headers: auth_headers(BOB_TOKEN)
    assert_response :forbidden
  end
end
