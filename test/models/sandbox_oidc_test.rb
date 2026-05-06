require "test_helper"

class SandboxOidcTest < ActiveSupport::TestCase
  test "default project and sandbox OIDC defaults are disabled" do
    user = User.create!(
      name: "charlie",
      email_address: "charlie@example.com",
      password: "password",
      password_confirmation: "password"
    )
    sandbox = user.sandboxes.create!(name: "cloudbox", image: SandboxManager::DEFAULT_IMAGE)

    assert_not user.default_project.oidc_enabled
    assert_not sandbox.oidc_enabled
  end

  test "rotate_oidc_secret returns authenticating runtime token" do
    sandbox = sandboxes(:alice_running)
    sandbox.update!(oidc_enabled: true)

    token = sandbox.rotate_oidc_secret!

    assert_equal sandbox, Sandbox.authenticate_oidc_runtime_token(token)
    assert sandbox.oidc_secret_digest.present?
    assert sandbox.oidc_secret_rotated_at.present?
  end

  test "old oidc runtime token stops authenticating after rotation" do
    sandbox = sandboxes(:alice_running)
    sandbox.update!(oidc_enabled: true)
    old_token = sandbox.rotate_oidc_secret!
    new_token = sandbox.rotate_oidc_secret!

    assert_nil Sandbox.authenticate_oidc_runtime_token(old_token)
    assert_equal sandbox, Sandbox.authenticate_oidc_runtime_token(new_token)
  end

  test "disabled sandbox runtime token does not authenticate" do
    sandbox = sandboxes(:alice_running)
    sandbox.update!(oidc_enabled: true)
    token = sandbox.rotate_oidc_secret!
    sandbox.update!(oidc_enabled: false)

    assert_nil Sandbox.authenticate_oidc_runtime_token(token)
  end
end
