# frozen_string_literal: true

require "test_helper"

class TailscaleManagerTest < ActiveSupport::TestCase
  setup do
    DockerMock.reset!
    @user = users(:one)
  end

  test "kernel sidecar uses runc runtime for subnet routing" do
    ENV.delete("SANDCASTLE_TAILSCALE_USERSPACE")

    TailscaleManager.new.send(
      :create_sidecar,
      name: "sc-ts-alice",
      user: @user,
      network: "sc-ts-net-alice",
      subnet: "10.140.131.0/24",
      auth_key: nil
    )

    options = DockerMock.created_options.last
    host_config = options.fetch("HostConfig")

    assert_equal "runc", host_config["Runtime"]
    assert_equal "sc-ts-net-alice", host_config["NetworkMode"]
    assert_equal({ "net.ipv4.ip_forward" => "1" }, host_config["Sysctls"])
    assert_includes host_config["Binds"], "/lib/modules:/lib/modules:ro"
    assert_includes host_config["CapAdd"], "NET_ADMIN"
    assert_includes host_config["CapAdd"], "SYS_MODULE"
    assert_includes host_config["Devices"], {
      "PathOnHost" => "/dev/net/tun",
      "PathInContainer" => "/dev/net/tun",
      "CgroupPermissions" => "rwm"
    }
  end

  test "restore repeats configured advertise tag" do
    original_tag = TailscaleManager::TAILSCALE_TAG
    TailscaleManager.send(:remove_const, :TAILSCALE_TAG)
    TailscaleManager.const_set(:TAILSCALE_TAG, "tag:sandcastle")

    @user.update!(
      tailscale_state: "disabled",
      tailscale_container_id: nil,
      tailscale_network: nil,
      tailscale_subnet: "10.140.131.0/24"
    )
    DockerMock.images[TailscaleManager::TAILSCALE_IMAGE] = {
      "Id" => "sha256:tailscale",
      "RepoTags" => [ TailscaleManager::TAILSCALE_IMAGE ],
      "Size" => 1_000_000,
      "Created" => Time.current.to_i
    }

    TailscaleManager.new.restore_from_state(user: @user)

    up_call = DockerMock.exec_calls.find { |call| call[:cmd].join(" ").include?("tailscale up") }
    assert up_call, "expected tailscale up to run during restore"
    assert_includes up_call[:cmd][2], "--advertise-routes=10.140.131.0/24"
    assert_includes up_call[:cmd][2], "--advertise-tags=tag:sandcastle"
  ensure
    TailscaleManager.send(:remove_const, :TAILSCALE_TAG)
    TailscaleManager.const_set(:TAILSCALE_TAG, original_tag)
  end
end
