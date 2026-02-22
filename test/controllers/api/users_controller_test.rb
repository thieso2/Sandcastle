# frozen_string_literal: true

require "test_helper"

class Api::UsersControllerTest < ActionDispatch::IntegrationTest
  # alice is admin (fixture users.yml), bob is not

  # --- index ---

  test "admin can list all users" do
    get "/api/users", headers: auth_headers   # alice is admin
    assert_response :ok
    body = JSON.parse(response.body)
    emails = body.map { |u| u["email_address"] }
    assert_includes emails, "alice@example.com"
    assert_includes emails, "bob@example.com"
  end

  test "non-admin cannot list users" do
    get "/api/users", headers: auth_headers(BOB_TOKEN)
    assert_response :forbidden
  end

  test "index returns 401 without auth" do
    get "/api/users"
    assert_response :unauthorized
  end

  # --- show ---

  test "admin can show any user" do
    get "/api/users/#{users(:two).id}", headers: auth_headers
    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal "bob@example.com", body["email_address"]
  end

  test "non-admin cannot show another user" do
    get "/api/users/#{users(:one).id}", headers: auth_headers(BOB_TOKEN)
    assert_response :forbidden
  end

  test "show includes sandbox list" do
    get "/api/users/#{users(:one).id}", headers: auth_headers
    assert_response :ok
    body = JSON.parse(response.body)
    assert body.key?("sandboxes")
    assert_kind_of Array, body["sandboxes"]
  end

  # --- create ---

  test "admin can create a new user" do
    post "/api/users",
      params: {
        name: "charlie",
        email_address: "charlie@example.com",
        password: "securepass123",
        password_confirmation: "securepass123"
      },
      headers: auth_headers
    assert_response :created
    body = JSON.parse(response.body)
    assert_equal "charlie@example.com", body["email_address"]
  end

  test "non-admin cannot create users" do
    post "/api/users",
      params: { name: "hacker", email_address: "h@example.com", password: "pw12345678" },
      headers: auth_headers(BOB_TOKEN)
    assert_response :forbidden
  end

  # --- update ---

  test "admin can update a user" do
    patch "/api/users/#{users(:two).id}",
      params: { ssh_public_key: "ssh-ed25519 AAAA test key" },
      headers: auth_headers
    assert_response :ok
  end

  # --- destroy ---

  test "admin can destroy a user" do
    # Create a temporary user to destroy (to avoid fixture dependency order issues)
    temp = User.create!(
      name: "temporary",
      email_address: "temp@example.com",
      password: "temppass123"
    )
    delete "/api/users/#{temp.id}", headers: auth_headers
    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal "deleted", body["status"]
  end

  test "non-admin cannot destroy users" do
    delete "/api/users/#{users(:one).id}", headers: auth_headers(BOB_TOKEN)
    assert_response :forbidden
  end
end
