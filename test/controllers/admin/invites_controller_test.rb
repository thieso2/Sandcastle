require "test_helper"

class Admin::InvitesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:one)
    sign_in_as(@admin)
  end

  test "index lists all invites for admin" do
    get admin_invites_path
    assert_response :success
  end

  test "create sends invite and redirects" do
    assert_difference "Invite.count", 1 do
      post admin_invites_path, params: { invite: { email: "fresh@example.com", message: "Welcome!" } }
    end

    assert_redirected_to admin_invites_path
    assert_match "Invite sent to", flash[:notice]

    invite = Invite.find_by(email: "fresh@example.com")
    assert_not_nil invite
    assert_equal @admin, invite.invited_by
    assert_equal "Welcome!", invite.message
  end

  test "create with invalid email redirects with alert" do
    assert_no_difference "Invite.count" do
      post admin_invites_path, params: { invite: { email: "not-an-email" } }
    end

    assert_redirected_to admin_invites_path
    assert flash[:alert].present?
  end

  test "destroy revokes a pending invite" do
    invite = invites(:pending_invite)

    assert_difference "Invite.count", -1 do
      delete admin_invite_path(invite)
    end

    assert_redirected_to admin_invites_path
    assert_equal "Invite revoked.", flash[:notice]
  end

  test "destroy cannot revoke an accepted invite" do
    invite = invites(:accepted_invite)

    assert_no_difference "Invite.count" do
      delete admin_invite_path(invite)
    end

    assert_redirected_to admin_invites_path
    assert flash[:alert].present?
  end

  test "non-admin cannot access invites index" do
    sign_out
    sign_in_as(users(:two))

    get admin_invites_path
    assert_redirected_to root_path
  end
end
