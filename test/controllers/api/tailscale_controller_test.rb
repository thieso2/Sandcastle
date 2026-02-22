# frozen_string_literal: true

require "test_helper"

class Api::TailscaleControllerTest < ActionDispatch::IntegrationTest
  # TailscaleMock is enabled globally in test_helper.rb

  # --- enable ---

  test "enable returns 201 with status enabled" do
    post "/api/tailscale/enable",
      params: { auth_key: "tskey-auth-test" },
      headers: auth_headers
    assert_response :created
    body = JSON.parse(response.body)
    assert_equal "enabled", body["status"]
  end

  test "enable returns 401 without auth" do
    post "/api/tailscale/enable", params: { auth_key: "tskey-auth-test" }
    assert_response :unauthorized
  end

  # --- login (interactive flow) ---

  test "login returns 201 with login_url" do
    post "/api/tailscale/login", headers: auth_headers
    assert_response :created
    body = JSON.parse(response.body)
    assert body["login_url"].present?
    assert_match %r{https://login\.tailscale\.com}, body["login_url"]
  end

  # --- login_status ---

  test "login_status returns pending when state is pending" do
    users(:one).update!(tailscale_state: "pending")

    get "/api/tailscale/login_status", headers: auth_headers
    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal "pending", body["status"]
  end

  test "login_status returns enabled when authentication completed" do
    users(:one).update!(tailscale_state: "enabled")

    get "/api/tailscale/login_status", headers: auth_headers
    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal "enabled", body["status"]
  end

  # --- update_settings ---

  test "update_settings saves auto_connect preference" do
    patch "/api/tailscale/update_settings",
      params: { auto_connect: true },
      headers: auth_headers
    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal true, body["auto_connect"]
    assert users(:one).reload.tailscale_auto_connect?
  end

  # --- disable ---

  test "disable returns status disabled" do
    users(:one).update!(tailscale_state: "enabled", tailscale_network: "sc-ts-net-alice")

    delete "/api/tailscale/disable", headers: auth_headers
    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal "disabled", body["status"]
    assert_equal "disabled", users(:one).reload.tailscale_state
  end

  # --- status ---

  test "status returns state and sidecar_running fields" do
    get "/api/tailscale/status", headers: auth_headers
    assert_response :ok
    body = JSON.parse(response.body)
    assert body.key?("state")
    assert body.key?("sidecar_running")
  end
end
