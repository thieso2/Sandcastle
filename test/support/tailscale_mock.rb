# frozen_string_literal: true

# Minitest-level stubs for TailscaleManager.
# Call TailscaleMock.enable! in a test setup block to replace live Docker calls
# with no-op stubs that return canned responses.
module TailscaleMock
  LOGIN_URL = "https://login.tailscale.com/a/test123"

  def self.enable!
    TailscaleManager.prepend(InstanceStubs)
  end

  module InstanceStubs
    def enable(user:, auth_key:)
      user.update!(
        tailscale_state: "enabled",
        tailscale_auto_connect: true,
        tailscale_network: "sc-ts-net-#{user.name}"
      )
      user
    end

    def start_login(user:)
      user.update!(tailscale_state: "pending")
      { login_url: TailscaleMock::LOGIN_URL, status: "pending" }
    end

    def check_login(user:)
      if user.tailscale_pending?
        { status: "pending", login_url: TailscaleMock::LOGIN_URL }
      else
        { status: "enabled" }
      end
    end

    def disable(user:)
      user.update!(tailscale_state: "disabled", tailscale_network: nil, tailscale_container_id: nil)
    end

    def status(user:)
      { state: user.tailscale_state, sidecar_running: false }
    end

    def connect_sandbox(sandbox:)
      sandbox.update!(tailscale: true)
    end

    def disconnect_sandbox(sandbox:)
      sandbox.update!(tailscale: false)
    end

    def sandbox_tailscale_ip(sandbox:)
      nil
    end

    def restore_from_state(user:)
      user.update!(tailscale_state: "enabled", tailscale_auto_connect: true)
      user
    end
  end
end
