# frozen_string_literal: true

# Stub VncManager so tests don't write Traefik YAML or perform TCP checks.
module VncMock
  STUB_URL = "/novnc/vnc.html?path=/vnc/1/websockify&autoconnect=true"

  def self.enable!
    VncManager.prepend(InstanceStubs)
  end

  module InstanceStubs
    def open(sandbox:)
      raise VncManager::Error, "Sandbox is not running" unless sandbox.status == "running"
      "/novnc/vnc.html?path=/vnc/#{sandbox.id}/websockify&autoconnect=true"
    end

    def close(sandbox:)
      # no-op
    end

    def active?(sandbox:)
      sandbox.status == "running"
    end

    def prepare_traefik_config(sandbox)
      # no-op: skip filesystem operations in tests
      true
    end

    def write_traefik_config(sandbox)
      # no-op
      true
    end
  end
end
