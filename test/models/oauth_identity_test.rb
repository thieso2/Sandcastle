require "test_helper"

class OauthIdentityTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
  end

  test "valid identity" do
    identity = @user.oauth_identities.build(provider: "github", uid: "12345")
    assert identity.valid?
  end

  test "requires provider" do
    identity = @user.oauth_identities.build(uid: "12345")
    assert_not identity.valid?
  end

  test "requires uid" do
    identity = @user.oauth_identities.build(provider: "github")
    assert_not identity.valid?
  end

  test "enforces unique provider+uid" do
    @user.oauth_identities.create!(provider: "github", uid: "12345")
    other_user = users(:two)
    duplicate = other_user.oauth_identities.build(provider: "github", uid: "12345")
    assert_not duplicate.valid?
  end

  test "user can have multiple providers" do
    @user.oauth_identities.create!(provider: "github", uid: "gh-123")
    google = @user.oauth_identities.build(provider: "google", uid: "g-456")
    assert google.valid?
  end
end
