require "test_helper"

class RegistrationsControllerTest < ActionDispatch::IntegrationTest
  test "new renders registration form for a valid pending invite" do
    invite = invites(:pending_invite)
    get new_registration_path(token: invite.token)
    assert_response :success
  end

  test "new redirects with alert for invalid token" do
    get new_registration_path(token: "invalid_token")
    assert_redirected_to new_session_path
    assert_equal "Invite link is invalid.", flash[:alert]
  end

  test "new redirects with alert for already accepted invite" do
    invite = invites(:accepted_invite)
    get new_registration_path(token: invite.token)
    assert_redirected_to new_session_path
    assert_equal "This invite has already been used.", flash[:alert]
  end

  test "new redirects with alert for expired invite" do
    invite = invites(:expired_invite)
    get new_registration_path(token: invite.token)
    assert_redirected_to new_session_path
    assert_equal "This invite has expired.", flash[:alert]
  end

  test "create registers user and marks invite accepted" do
    invite = invites(:pending_invite)

    assert_difference "User.count", 1 do
      post accept_registration_path(token: invite.token), params: {
        user: {
          name: "newuser",
          password: "password123",
          password_confirmation: "password123"
        }
      }
    end

    assert_redirected_to root_path
    assert_equal "Welcome to Sandcastle! Your account is now active.", flash[:notice]

    user = User.find_by(name: "newuser")
    assert_not_nil user
    assert_equal invite.email, user.email_address
    assert_not_nil invite.reload.accepted_at
  end

  test "create pre-fills email from invite regardless of submitted value" do
    invite = invites(:pending_invite)

    post accept_registration_path(token: invite.token), params: {
      user: {
        name: "newuser2",
        password: "password123",
        password_confirmation: "password123"
      }
    }

    user = User.find_by(name: "newuser2")
    assert_equal invite.email, user.email_address
  end

  test "create re-renders form on invalid user data" do
    invite = invites(:pending_invite)

    assert_no_difference "User.count" do
      post accept_registration_path(token: invite.token), params: {
        user: {
          name: "",
          password: "password123",
          password_confirmation: "password123"
        }
      }
    end

    assert_response :unprocessable_entity
    assert_nil invite.reload.accepted_at
  end

  test "create does not accept an already accepted invite" do
    invite = invites(:accepted_invite)

    post accept_registration_path(token: invite.token), params: {
      user: { name: "hacker", password: "password123", password_confirmation: "password123" }
    }

    assert_redirected_to new_session_path
  end
end
