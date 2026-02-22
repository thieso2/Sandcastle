# frozen_string_literal: true

require "test_helper"

class TailscaleManagerTest < ActiveSupport::TestCase
  setup do
    @manager = TailscaleManager.new
    @user = users(:one)
    @user.update!(tailscale_state: "disabled", tailscale_container_id: nil, tailscale_network: nil)
    DockerMock.enable!
  end

  # -- restore_from_state ---------------------------------------------------

  test "restore_from_state calls tailscale up with advertise-routes" do
    exec_calls = []

    Docker::Container.prepend(Module.new do
      define_method(:exec) do |cmd, opts = {}|
        exec_calls << cmd
        [ [], [], 0 ]
      end
    end)

    @manager.restore_from_state(user: @user)

    advertise_call = exec_calls.find { |cmd| cmd.join(" ").include?("advertise-routes") }
    assert_not_nil advertise_call, "Expected container.exec to be called with --advertise-routes"
    assert_match %r{tailscale up}, advertise_call.join(" ")
    assert_match %r{--advertise-routes=\d+\.\d+\.\d+\.\d+/\d+}, advertise_call.join(" ")
  end

  test "restore_from_state sets user state to enabled" do
    @manager.restore_from_state(user: @user)

    assert @user.reload.tailscale_enabled?
    assert @user.tailscale_auto_connect
    assert_not_nil @user.tailscale_container_id
    assert_not_nil @user.tailscale_network
  end

  test "restore_from_state raises when tailscale already active" do
    @user.update!(tailscale_state: "enabled")

    assert_raises(TailscaleManager::Error) do
      @manager.restore_from_state(user: @user)
    end
  end
end
