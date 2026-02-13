# frozen_string_literal: true

require "application_system_test_case"

class SandboxLifecycleTest < ApplicationSystemTestCase
  setup do
    @user = users(:thies)
    login_as(@user)
    DockerMock.reset!
  end

  test "complete sandbox lifecycle: create, view, start, stop, destroy" do
    # Navigate to dashboard
    visit root_path
    assert_text "Dashboard"

    # Create new sandbox
    click_on "New Sandbox"
    fill_in "Name", with: "test-lifecycle"
    check "Persistent volume"
    click_on "Create Sandbox"

    # Should see flash message
    assert_text "Creating sandbox"

    # Wait for provision job to complete
    perform_enqueued_jobs

    # Should see sandbox in list
    visit root_path
    assert_text "test-lifecycle"
    assert_text "running"

    # Stop sandbox
    within "#sandbox_test-lifecycle" do
      click_on "Stop"
    end

    # Wait for stop job
    perform_enqueued_jobs

    # Should see stopped status
    visit root_path
    within "#sandbox_test-lifecycle" do
      assert_text "stopped"
    end

    # Start sandbox again
    within "#sandbox_test-lifecycle" do
      click_on "Start"
    end

    # Wait for start job
    perform_enqueued_jobs

    # Should see running status
    visit root_path
    within "#sandbox_test-lifecycle" do
      assert_text "running"
    end

    # Destroy sandbox
    within "#sandbox_test-lifecycle" do
      accept_confirm do
        click_on "Destroy"
      end
    end

    # Wait for destroy job
    perform_enqueued_jobs

    # Should no longer see sandbox in list (destroyed sandboxes are hidden)
    visit root_path
    assert_no_text "test-lifecycle"
  end

  test "flash messages auto-dismiss" do
    visit root_path

    # Create sandbox to trigger flash
    click_on "New Sandbox"
    fill_in "Name", with: "flash-test"
    click_on "Create Sandbox"

    # Flash should appear
    assert_selector "[data-controller='flash']"
    assert_text "Creating sandbox"

    # Wait for auto-dismiss (5 seconds)
    using_wait_time(6) do
      assert_no_selector "[data-controller='flash']"
    end
  end

  test "stats load asynchronously" do
    # Create a running sandbox first
    sandbox = @user.sandboxes.create!(
      name: "stats-test",
      status: "pending",
      image: "ghcr.io/thieso2/sandcastle-sandbox:latest"
    )

    perform_enqueued_jobs do
      SandboxProvisionJob.perform_later(sandbox_id: sandbox.id)
    end

    visit root_path

    # Stats frame should load
    within "#sandbox_#{sandbox.name}" do
      # Initially shows loading or stats
      assert_selector "turbo-frame[src*='/sandboxes/#{sandbox.id}/stats']"
    end
  end

  private

  def login_as(user)
    visit new_session_path
    fill_in "Email address", with: user.email_address
    fill_in "Password", with: "Secret1*3*5*"
    click_on "Sign in"
  end
end
