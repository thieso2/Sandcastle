# frozen_string_literal: true

require "application_system_test_case"

class SandboxLifecycleTest < ApplicationSystemTestCase
  setup do
    @user = users(:thies)
    @original_ensure_mount_dirs = SandboxManager.instance_method(:ensure_mount_dirs)
    SandboxManager.define_method(:ensure_mount_dirs) { |_user, _sandbox| true }
    ENV["SANDCASTLE_NAME"] = "test-castle"
    DockerMock.reset!
  end

  teardown do
    SandboxManager.define_method(:ensure_mount_dirs, @original_ensure_mount_dirs)
    ENV.delete("SANDCASTLE_NAME")
  end

  test "creating a sandbox from a saved project sets a project-specific hostname" do
    login_as(@user)

    click_on "Create Sandcastle"
    assert_text "Create Sandcastle"

    click_on "New Project"
    assert_text "Create Project"

    fill_in "Name", with: "alpha"
    fill_in "Project Subdir", with: "projects/alpha"
    click_on "Create Project"

    assert_text "Project alpha created."
    assert_text "Create Sandcastle"

    fill_in "sandbox_name", with: "promptbox"
    select "alpha (projects/alpha)", from: "sandbox_project_id"
    click_on "Create Sandcastle"

    assert_text "Creating sandcastle promptbox"

    perform_enqueued_jobs

    sandbox = @user.sandboxes.find_by!(name: "promptbox")
    assert_equal "alpha", sandbox.project_name
    assert_equal "promptbox-alpha", sandbox.hostname

    container = Docker::Container.get(sandbox.container_id)
    assert_equal "promptbox.alpha.test-castle", container.json.dig("Config", "Hostname")
    assert_equal sandbox.full_name, container.json.dig("Config", "name")
  end

  private

  def login_as(user)
    visit new_session_path
    fill_in "email_address", with: user.email_address
    fill_in "password", with: "password"
    click_on "Sign in"
    assert_text "My Sandcastles"
  end
end
