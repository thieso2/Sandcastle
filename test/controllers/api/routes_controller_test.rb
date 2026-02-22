# frozen_string_literal: true

require "test_helper"

class Api::RoutesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @sandbox = sandboxes(:alice_running)
  end

  # --- index ---

  test "index lists routes for sandbox" do
    # Add a route to the fixture sandbox so there's something to list
    @sandbox.routes.create!(mode: "http", domain: "test.example.com", port: 8080)

    get "/api/sandboxes/#{@sandbox.id}/routes", headers: auth_headers
    assert_response :ok
    body = JSON.parse(response.body)
    assert_kind_of Array, body
    assert_equal 1, body.size
    assert_equal "test.example.com", body.first["domain"]
  end

  test "index returns empty array when no routes" do
    get "/api/sandboxes/#{@sandbox.id}/routes", headers: auth_headers
    assert_response :ok
    assert_equal [], JSON.parse(response.body)
  end

  test "index returns 401 without auth" do
    get "/api/sandboxes/#{@sandbox.id}/routes"
    assert_response :unauthorized
  end

  test "index returns 404 for sandbox not owned by user" do
    get "/api/sandboxes/#{sandboxes(:bob_running).id}/routes", headers: auth_headers
    assert_response :not_found
  end

  # --- create HTTP route ---

  test "create HTTP route returns 201 with route JSON" do
    # RouteManager writes a Traefik config file and connects to Docker network.
    # Both are mocked by DockerMock; we also stub filesystem writes.
    Dir.mktmpdir do |dir|
      stub_const(RouteManager, :DYNAMIC_DIR, dir) do
        post "/api/sandboxes/#{@sandbox.id}/routes",
          params: { domain: "myapp.example.com", port: 3000, mode: "http" },
          headers: auth_headers
        assert_response :created
        body = JSON.parse(response.body)
        assert_equal "myapp.example.com", body["domain"]
        assert_equal 3000, body["port"]
        assert_equal "http", body["mode"]
      end
    end
  end

  # --- destroy ---

  test "destroy removes route and returns status removed" do
    route = @sandbox.routes.create!(mode: "http", domain: "remove.example.com", port: 9090)

    Dir.mktmpdir do |dir|
      stub_const(RouteManager, :DYNAMIC_DIR, dir) do
        delete "/api/sandboxes/#{@sandbox.id}/routes/#{route.id}", headers: auth_headers
        assert_response :ok
        body = JSON.parse(response.body)
        assert_equal "removed", body["status"]
      end
    end
  end

  test "destroy returns 404 for non-existent route" do
    delete "/api/sandboxes/#{@sandbox.id}/routes/0", headers: auth_headers
    assert_response :not_found
  end

  private

  # Temporarily override a constant for the duration of a block.
  def stub_const(mod, name, value)
    old = mod.const_get(name)
    mod.send(:remove_const, name)
    mod.const_set(name, value)
    yield
  ensure
    mod.send(:remove_const, name)
    mod.const_set(name, old)
  end
end
