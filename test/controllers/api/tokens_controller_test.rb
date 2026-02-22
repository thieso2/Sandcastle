# frozen_string_literal: true

require "test_helper"

class Api::TokensControllerTest < ActionDispatch::IntegrationTest
  # --- index ---

  test "index lists tokens for the authenticated user" do
    get "/api/tokens", headers: auth_headers
    assert_response :ok
    body = JSON.parse(response.body)
    assert_kind_of Array, body
    # alice has alice_token fixture
    prefixes = body.map { |t| t["prefix"] }
    assert_includes prefixes, "sc_testaaaa"
  end

  test "index returns 401 without auth" do
    get "/api/tokens"
    assert_response :unauthorized
  end

  # --- create (password auth) ---

  test "create with valid credentials returns raw_token once" do
    post "/api/tokens",
      params: { email_address: "alice@example.com", password: "password", name: "CLI token" }
    assert_response :created
    body = JSON.parse(response.body)
    assert body["raw_token"].present?
    assert_match /\Asc_/, body["raw_token"]
    assert body.key?("id")
    assert body.key?("prefix")
  end

  test "create with wrong credentials returns 401" do
    post "/api/tokens",
      params: { email_address: "alice@example.com", password: "wrong", name: "bad" }
    assert_response :unauthorized
  end

  test "create with missing name returns 400" do
    post "/api/tokens",
      params: { email_address: "alice@example.com", password: "password" }
    assert_response :bad_request
  end

  # --- destroy ---

  test "destroy removes token and returns deleted status" do
    token = api_tokens(:alice_token)
    delete "/api/tokens/#{token.id}", headers: auth_headers
    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal "deleted", body["status"]
  end

  test "destroy returns 404 for token not owned by user" do
    token = api_tokens(:bob_token)
    delete "/api/tokens/#{token.id}", headers: auth_headers
    assert_response :not_found
  end
end
