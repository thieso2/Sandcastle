require "test_helper"

class Admin::SettingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:one)   # alice, admin
    @user = users(:two)    # bob, non-admin
    sign_in_as(@admin)
  end

  test "admin can access settings edit" do
    get edit_admin_settings_path
    assert_response :success
  end

  test "non-admin is redirected from settings" do
    sign_out
    sign_in_as(@user)
    get edit_admin_settings_path
    assert_redirected_to root_path
  end

  test "admin can update oauth settings" do
    patch admin_settings_path, params: { setting: {
      github_client_id: "new_github_id",
      github_client_secret: "new_github_secret",
      google_client_id: "new_google_id",
      google_client_secret: "new_google_secret"
    } }

    assert_redirected_to edit_admin_settings_path
    setting = Setting.instance.reload
    assert_equal "new_github_id", setting.github_client_id
    assert_equal "new_github_secret", setting.github_client_secret
  end

  test "admin can update smtp settings" do
    patch admin_settings_path, params: { setting: {
      smtp_address: "smtp.test.com",
      smtp_port: 465,
      smtp_username: "testuser",
      smtp_password: "testpass",
      smtp_authentication: "login",
      smtp_starttls: false,
      smtp_from_address: "noreply@test.com"
    } }

    assert_redirected_to edit_admin_settings_path
    setting = Setting.instance.reload
    assert_equal "smtp.test.com", setting.smtp_address
    assert_equal 465, setting.smtp_port
    assert_equal "login", setting.smtp_authentication
    assert_equal false, setting.smtp_starttls
  end

  test "blank secret preserves existing value" do
    Setting.instance.update!(github_client_secret: "existing_secret")

    patch admin_settings_path, params: { setting: {
      github_client_id: "updated_id",
      github_client_secret: ""
    } }

    setting = Setting.instance.reload
    assert_equal "updated_id", setting.github_client_id
    assert_equal "existing_secret", setting.github_client_secret
  end
end
