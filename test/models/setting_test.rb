require "test_helper"

class SettingTest < ActiveSupport::TestCase
  setup do
    Setting.delete_all
  end

  test "instance returns singleton" do
    setting = Setting.instance
    assert_equal 1, setting.id
    assert_equal setting, Setting.instance
  end

  test "class-level accessor falls back to ENV" do
    ENV["GITHUB_CLIENT_ID"] = "env_id"
    assert_equal "env_id", Setting.github_client_id
  ensure
    ENV.delete("GITHUB_CLIENT_ID")
  end

  test "class-level accessor prefers DB over ENV" do
    ENV["GITHUB_CLIENT_ID"] = "env_id"
    Setting.instance.update!(github_client_id: "db_id")
    assert_equal "db_id", Setting.github_client_id
  ensure
    ENV.delete("GITHUB_CLIENT_ID")
  end

  test "github_configured? requires both id and secret" do
    refute Setting.github_configured?

    Setting.instance.update!(github_client_id: "id")
    refute Setting.github_configured?

    Setting.instance.update!(github_client_secret: "secret")
    assert Setting.github_configured?
  end

  test "google_configured? requires both id and secret" do
    refute Setting.google_configured?

    Setting.instance.update!(google_client_id: "id", google_client_secret: "secret")
    assert Setting.google_configured?
  end

  test "smtp_configured? requires address" do
    refute Setting.smtp_configured?

    Setting.instance.update!(smtp_address: "smtp.example.com")
    assert Setting.smtp_configured?
  end

  test "blank secret skips update" do
    Setting.instance.update!(github_client_secret: "original")
    Setting.instance.update!(github_client_secret: "")
    assert_equal "original", Setting.instance.reload.github_client_secret
  end

  test "smtp_settings returns hash when configured" do
    setting = Setting.instance
    setting.update!(smtp_address: "smtp.example.com", smtp_port: 465, smtp_username: "user", smtp_password: "pass")

    expected = {
      address: "smtp.example.com",
      port: 465,
      user_name: "user",
      password: "pass",
      authentication: :plain,
      enable_starttls_auto: true
    }
    assert_equal expected, setting.smtp_settings
  end

  test "smtp_settings returns empty hash when not configured" do
    assert_equal({}, Setting.instance.smtp_settings)
  end

  test "encrypts secrets" do
    Setting.instance.update!(github_client_secret: "my_secret")
    raw = ActiveRecord::Base.connection.select_value("SELECT github_client_secret FROM settings WHERE id = 1")
    refute_equal "my_secret", raw
    assert_equal "my_secret", Setting.instance.github_client_secret
  end
end
