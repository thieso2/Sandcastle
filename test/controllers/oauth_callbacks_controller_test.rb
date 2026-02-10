require "test_helper"

class OauthCallbacksControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)  # alice, admin, active
    OmniAuth.config.test_mode = true
  end

  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:github] = nil
    OmniAuth.config.mock_auth[:google] = nil
  end

  # --- GitHub OAuth ---

  test "github oauth signs in existing user with linked identity" do
    @user.oauth_identities.create!(provider: "github", uid: "12345")

    mock_github_auth(uid: "12345", email: @user.email_address, nickname: @user.name)
    post "/auth/github"
    follow_redirect!

    assert_redirected_to root_path
    assert cookies[:session_id]
  end

  test "github oauth links identity and signs in when email matches existing user" do
    mock_github_auth(uid: "99999", email: @user.email_address, nickname: "alicegithub")
    post "/auth/github"
    follow_redirect!

    assert_redirected_to root_path
    assert cookies[:session_id]
    assert @user.oauth_identities.exists?(provider: "github", uid: "99999")
  end

  test "github oauth creates new user with pending_approval status" do
    mock_github_auth(uid: "77777", email: "newdev@example.com", nickname: "newdev")
    post "/auth/github"
    follow_redirect!

    assert_redirected_to new_session_path
    assert_match /admin must approve/, flash[:notice]
    new_user = User.find_by(email_address: "newdev@example.com")
    assert_equal "pending_approval", new_user.status
    assert_equal "newdev", new_user.name
    assert new_user.oauth_identities.exists?(provider: "github", uid: "77777")
  end

  test "github oauth rejects suspended user" do
    @user.update!(status: "suspended")
    @user.oauth_identities.create!(provider: "github", uid: "12345")

    mock_github_auth(uid: "12345", email: @user.email_address, nickname: @user.name)
    post "/auth/github"
    follow_redirect!

    assert_redirected_to new_session_path
    assert_match /suspended/, flash[:alert]
  end

  test "github oauth rejects pending_approval user" do
    @user.update!(status: "pending_approval")
    @user.oauth_identities.create!(provider: "github", uid: "12345")

    mock_github_auth(uid: "12345", email: @user.email_address, nickname: @user.name)
    post "/auth/github"
    follow_redirect!

    assert_redirected_to new_session_path
    assert_match /pending admin approval/, flash[:alert]
  end

  # --- Google OAuth ---

  test "google oauth signs in existing user with linked identity" do
    @user.oauth_identities.create!(provider: "google", uid: "g-12345")

    mock_google_auth(uid: "g-12345", email: @user.email_address)
    post "/auth/google"
    follow_redirect!

    assert_redirected_to root_path
    assert cookies[:session_id]
  end

  test "google oauth creates new user from email prefix" do
    mock_google_auth(uid: "g-88888", email: "janedoe@gmail.com")
    post "/auth/google"
    follow_redirect!

    assert_redirected_to new_session_path
    new_user = User.find_by(email_address: "janedoe@gmail.com")
    assert_equal "pending_approval", new_user.status
    assert_equal "janedoe", new_user.name
  end

  # --- Username collision ---

  test "oauth handles username collision by appending number" do
    mock_github_auth(uid: "55555", email: "alice-new@example.com", nickname: "alice")
    post "/auth/github"
    follow_redirect!

    new_user = User.find_by(email_address: "alice-new@example.com")
    assert_equal "alice2", new_user.name
  end

  # --- Failure ---

  test "oauth failure redirects to login with error" do
    get "/auth/failure", params: { message: "invalid_credentials" }

    assert_redirected_to new_session_path
    assert_match /invalid credentials/i, flash[:alert]
  end

  private

  def mock_github_auth(uid:, email:, nickname: "testuser")
    OmniAuth.config.mock_auth[:github] = OmniAuth::AuthHash.new(
      provider: "github",
      uid: uid,
      info: { email: email, nickname: nickname }
    )
  end

  def mock_google_auth(uid:, email:, name: "Test User")
    OmniAuth.config.mock_auth[:google] = OmniAuth::AuthHash.new(
      provider: "google",
      uid: uid,
      info: { email: email, name: name }
    )
  end
end
