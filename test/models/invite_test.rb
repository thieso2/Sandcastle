require "test_helper"

class InviteTest < ActiveSupport::TestCase
  setup do
    @admin = users(:one)
  end

  test "generates a token before validation on create" do
    invite = Invite.new(email: "new@example.com", invited_by: @admin)
    assert_nil invite.token
    invite.valid?
    assert_not_nil invite.token
  end

  test "token is urlsafe base64" do
    invite = Invite.create!(email: "new@example.com", invited_by: @admin)
    assert_match(/\A[A-Za-z0-9\-_]+\z/, invite.token)
  end

  test "token uniqueness is enforced" do
    existing = invites(:pending_invite)
    invite = Invite.new(email: "other@example.com", invited_by: @admin, token: existing.token)
    assert_not invite.valid?
    assert_includes invite.errors[:token], "has already been taken"
  end

  test "requires email" do
    invite = Invite.new(invited_by: @admin)
    assert_not invite.valid?
    assert_includes invite.errors[:email], "can't be blank"
  end

  test "requires valid email format" do
    invite = Invite.new(email: "not-an-email", invited_by: @admin)
    assert_not invite.valid?
    assert invite.errors[:email].any?
  end

  test "normalizes email to lowercase" do
    invite = Invite.new(email: "  USER@EXAMPLE.COM  ", invited_by: @admin)
    invite.valid?
    assert_equal "user@example.com", invite.email
  end

  test "sets default expiry of 7 days on create" do
    invite = Invite.create!(email: "new@example.com", invited_by: @admin)
    assert_not_nil invite.expires_at
    assert_in_delta 7.days.from_now, invite.expires_at, 5.seconds
  end

  test "pending? returns true for a pending invite" do
    assert invites(:pending_invite).pending?
  end

  test "pending? returns false for an accepted invite" do
    assert_not invites(:accepted_invite).pending?
  end

  test "pending? returns false for an expired invite" do
    assert_not invites(:expired_invite).pending?
  end

  test "accepted? returns true for an accepted invite" do
    assert invites(:accepted_invite).accepted?
  end

  test "accepted? returns false for a pending invite" do
    assert_not invites(:pending_invite).accepted?
  end

  test "expired? returns true for an expired invite" do
    assert invites(:expired_invite).expired?
  end

  test "expired? returns false for a pending invite" do
    assert_not invites(:pending_invite).expired?
  end

  test "status returns 'pending' for pending invite" do
    assert_equal "pending", invites(:pending_invite).status
  end

  test "status returns 'accepted' for accepted invite" do
    assert_equal "accepted", invites(:accepted_invite).status
  end

  test "status returns 'expired' for expired invite" do
    assert_equal "expired", invites(:expired_invite).status
  end

  test "accept! sets accepted_at" do
    invite = invites(:pending_invite)
    assert_nil invite.accepted_at
    invite.accept!
    assert_not_nil invite.reload.accepted_at
  end

  test "pending scope returns only pending invites" do
    pending = Invite.pending.pluck(:token)
    assert_includes pending, invites(:pending_invite).token
    assert_not_includes pending, invites(:accepted_invite).token
    assert_not_includes pending, invites(:expired_invite).token
  end

  test "accepted scope returns only accepted invites" do
    accepted = Invite.accepted.pluck(:token)
    assert_includes accepted, invites(:accepted_invite).token
    assert_not_includes accepted, invites(:pending_invite).token
  end

  test "expired scope returns only expired invites" do
    expired = Invite.expired.pluck(:token)
    assert_includes expired, invites(:expired_invite).token
    assert_not_includes expired, invites(:pending_invite).token
  end
end
