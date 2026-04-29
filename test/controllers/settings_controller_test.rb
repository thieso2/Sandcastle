require "test_helper"

class SettingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    sign_in_as(@user)
  end

  test "GET show renders" do
    get settings_path
    assert_response :success
  end

  test "PATCH update_profile updates default oidc setting" do
    patch update_profile_settings_path, params: {
      user: {
        email_address: @user.email_address,
        default_oidc_enabled: "1"
      },
      tab: "sandboxes"
    }

    assert_redirected_to settings_path(anchor: "sandboxes")
    assert @user.reload.default_oidc_enabled
  end

  test "PATCH update_gcp_oidc_configs creates reusable configs" do
    patch update_gcp_oidc_configs_settings_path, params: {
      tab: "gcp",
      gcp_oidc_configs: {
        "0" => {
          name: "prod",
          project_id: "test-project-123",
          project_number: "123456789012",
          workload_identity_pool_id: "sandcastle",
          workload_identity_provider_id: "sandcastle",
          workload_identity_location: "global"
        }
      }
    }

    assert_redirected_to settings_path(anchor: "gcp")
    config = @user.gcp_oidc_configs.find_by!(name: "prod")
    assert_equal "test-project-123", config.project_id
    assert_equal "123456789012", config.project_number
  end

  test "GET show renders GCP config impersonation setup command" do
    ENV["SANDCASTLE_HOST"] = "sandcastle.example.com"
    @user.gcp_oidc_configs.create!(
      name: "prod",
      project_id: "test-project-123",
      project_number: "123456789012",
      workload_identity_pool_id: "sandcastle",
      workload_identity_provider_id: "sandcastle"
    )

    get settings_path(anchor: "gcp")

    assert_response :success
    assert_includes @response.body, "roles/iam.workloadIdentityUser"
    assert_includes @response.body, "attribute.user/alice"
  ensure
    ENV.delete("SANDCASTLE_HOST")
  end

  test "PATCH update_gcp_oidc_configs removes selected configs" do
    config = @user.gcp_oidc_configs.create!(
      name: "prod",
      project_id: "test-project-123",
      project_number: "123456789012",
      workload_identity_pool_id: "sandcastle",
      workload_identity_provider_id: "sandcastle"
    )

    patch update_gcp_oidc_configs_settings_path, params: {
      tab: "gcp",
      gcp_oidc_configs: {
        "0" => {
          id: config.id,
          name: config.name,
          project_number: config.project_number,
          _destroy: "1"
        }
      }
    }

    assert_redirected_to settings_path(anchor: "gcp")
    assert_nil @user.gcp_oidc_configs.find_by(id: config.id)
  end

  test "PATCH update_persisted_paths replaces the user's persisted paths" do
    @user.persisted_paths.find_or_create_by!(path: ".claude")
    patch update_persisted_paths_settings_path, params: {
      persisted_paths: [ { path: ".npmrc-dir" }, { path: ".gh" } ]
    }
    assert_redirected_to settings_path

    paths = @user.persisted_paths.reload.pluck(:path)
    assert_equal [ ".gh", ".npmrc-dir" ], paths.sort
  end

  test "PATCH update_persisted_paths drops blank rows and dedups" do
    patch update_persisted_paths_settings_path, params: {
      persisted_paths: [ { path: ".x" }, { path: "" }, { path: ".x" } ]
    }
    assert_equal [ ".x" ], @user.persisted_paths.reload.where(path: ".x").pluck(:path)
  end

  test "PATCH update_persisted_paths flashes alert on invalid path" do
    patch update_persisted_paths_settings_path, params: {
      persisted_paths: [ { path: "../bad" } ]
    }
    assert_redirected_to settings_path
    assert_match(/must not contain/, flash[:alert].to_s)
  end

  test "PATCH update_injected_files creates a row with content" do
    patch update_injected_files_settings_path, params: {
      injected_files: [ { path: ".npmrc", content: "token=abc", mode: "600" } ]
    }
    assert_redirected_to settings_path

    inj = @user.injected_files.find_by!(path: ".npmrc")
    assert_equal "token=abc", inj.content
    assert_equal 0o600, inj.mode
  end

  test "PATCH update_injected_files updates existing row's content" do
    @user.injected_files.create!(path: ".npmrc", content: "old=val")

    patch update_injected_files_settings_path, params: {
      injected_files: [ { path: ".npmrc", content: "new=val", mode: "600" } ]
    }

    assert_equal "new=val", @user.injected_files.find_by!(path: ".npmrc").content
  end

  test "PATCH update_injected_files preserves content when content is blank on update" do
    @user.injected_files.create!(path: ".keepme", content: "DO_NOT_LOSE")

    patch update_injected_files_settings_path, params: {
      injected_files: [ { path: ".keepme", content: "", mode: "600" } ]
    }

    assert_equal "DO_NOT_LOSE", @user.injected_files.find_by!(path: ".keepme").content
  end

  test "PATCH update_injected_files removes rows not in submission" do
    @user.injected_files.create!(path: ".byebye", content: "x")
    @user.injected_files.create!(path: ".keepme", content: "y")

    patch update_injected_files_settings_path, params: {
      injected_files: [ { path: ".keepme", content: "", mode: "600" } ]
    }

    assert_nil @user.injected_files.find_by(path: ".byebye")
    assert_not_nil @user.injected_files.find_by(path: ".keepme")
  end

  test "DELETE delete_injected_file removes the row" do
    inj = @user.injected_files.create!(path: ".gone", content: "x")
    delete delete_injected_file_settings_path(id: inj.id)
    assert_redirected_to settings_path
    assert_nil @user.injected_files.find_by(id: inj.id)
  end
end
