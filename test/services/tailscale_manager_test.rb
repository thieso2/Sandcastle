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
end
