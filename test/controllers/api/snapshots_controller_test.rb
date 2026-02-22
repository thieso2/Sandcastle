# frozen_string_literal: true

require "test_helper"

class Api::SnapshotsControllerTest < ActionDispatch::IntegrationTest
  setup do
    # Pre-populate DockerMock with fixture containers so container operations work.
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

  test "index lists user's snapshots" do
    get "/api/snapshots", headers: auth_headers
    assert_response :ok
    body = JSON.parse(response.body)
    assert_kind_of Array, body
    names = body.map { |s| s["name"] }
    assert_includes names, "my-snapshot"
  end

  test "index returns 401 without auth" do
    get "/api/snapshots"
    assert_response :unauthorized
  end

  # --- show ---

  test "show returns snapshot JSON" do
    get "/api/snapshots/my-snapshot", headers: auth_headers
    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal "my-snapshot", body["name"]
  end

  test "show returns 404 for unknown snapshot" do
    get "/api/snapshots/does-not-exist", headers: auth_headers
    assert_response :not_found
  end

  test "show returns 403 for snapshot belonging to another user" do
    # alice's snapshot should not be accessible by bob
    get "/api/snapshots/my-snapshot", headers: auth_headers(BOB_TOKEN)
    assert_response :not_found
  end

  # --- create ---

  test "create snapshot returns 201" do
    post "/api/snapshots",
      params: { sandbox_id: sandboxes(:alice_running).id, name: "fresh-snap" },
      headers: auth_headers
    assert_response :created
    body = JSON.parse(response.body)
    assert_equal "fresh-snap", body["name"]
  end

  test "create returns 404 when sandbox not found" do
    post "/api/snapshots",
      params: { sandbox_id: 0, name: "nope" },
      headers: auth_headers
    assert_response :not_found
  end

  # --- destroy ---

  test "destroy removes snapshot" do
    delete "/api/snapshots/my-snapshot", headers: auth_headers
    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal "deleted", body["status"]
  end

  test "destroy returns 404 for unknown snapshot" do
    delete "/api/snapshots/ghost-snap", headers: auth_headers
    assert_response :not_found
  end
end
