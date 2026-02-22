# frozen_string_literal: true

require "test_helper"

class Api::InfosControllerTest < ActionDispatch::IntegrationTest
  setup do
    SystemStatus.any_instance.stubs(:memory_info).returns({ total_gb: 8.0, used_gb: 2.0, available_gb: 6.0, percent: 25.0 })
    SystemStatus.any_instance.stubs(:disk_info).returns({ total_gb: 100.0, used_gb: 20.0, available_gb: 80.0, percent: 20.0 })
    SystemStatus.any_instance.stubs(:load_average).returns({ one: 0.1, five: 0.2, fifteen: 0.3 })
    SystemStatus.any_instance.stubs(:uptime_info).returns("1d 2h 30m")
    SystemStatus.any_instance.stubs(:process_count).returns(42)
    SystemStatus.any_instance.stubs(:cpu_count).returns(4)
  end

  test "show returns version, rails, ruby, host, sandboxes, docker, users" do
    get "/api/info", headers: auth_headers
    assert_response :ok
    body = JSON.parse(response.body)
    assert body.key?("version")
    assert body.key?("rails")
    assert body.key?("ruby")
    assert body.key?("host")
    assert body.key?("sandboxes")
    assert body.key?("docker")
    assert body.key?("users")
  end

  test "users field contains total and admins counts" do
    get "/api/info", headers: auth_headers
    assert_response :ok
    users_data = JSON.parse(response.body)["users"]
    assert users_data.key?("total")
    assert users_data.key?("admins")
    assert users_data["total"] >= 2
    assert users_data["admins"] >= 1
  end

  test "show returns 401 without auth" do
    get "/api/info"
    assert_response :unauthorized
  end
end
