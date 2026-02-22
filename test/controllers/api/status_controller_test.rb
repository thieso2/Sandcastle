# frozen_string_literal: true

require "test_helper"

class Api::StatusControllerTest < ActionDispatch::IntegrationTest
  # Stub out the expensive system calls inside SystemStatus so tests don't
  # require /proc/meminfo, real Docker info, etc.
  setup do
    SystemStatus.any_instance.stubs(:memory_info).returns({ total_gb: 8.0, used_gb: 2.0, available_gb: 6.0, percent: 25.0 })
    SystemStatus.any_instance.stubs(:disk_info).returns({ total_gb: 100.0, used_gb: 20.0, available_gb: 80.0, percent: 20.0 })
    SystemStatus.any_instance.stubs(:load_average).returns({ one: 0.1, five: 0.2, fifteen: 0.3 })
    SystemStatus.any_instance.stubs(:uptime_info).returns("1d 2h 30m")
    SystemStatus.any_instance.stubs(:process_count).returns(42)
    SystemStatus.any_instance.stubs(:cpu_count).returns(4)
  end

  test "show returns docker, sandboxes, and host keys" do
    get "/api/status", headers: auth_headers
    assert_response :ok
    body = JSON.parse(response.body)
    assert body.key?("docker")
    assert body.key?("sandboxes")
    assert body.key?("host")
  end

  test "sandboxes section contains counts" do
    get "/api/status", headers: auth_headers
    assert_response :ok
    sandboxes = JSON.parse(response.body)["sandboxes"]
    assert sandboxes.key?("total")
    assert sandboxes.key?("running")
    assert sandboxes.key?("stopped")
    assert sandboxes.key?("pending")
  end

  test "show returns 401 without auth" do
    get "/api/status"
    assert_response :unauthorized
  end
end
