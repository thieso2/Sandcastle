# frozen_string_literal: true

# Stub TerminalManager so tests don't write Traefik YAML files.
module TerminalMock
  def self.enable!
    TerminalManager.prepend(InstanceStubs)
  end

  module InstanceStubs
    def write_traefik_config(sandbox)
      # no-op: skip filesystem operations in tests
      true
    end

    def prepare_traefik_config(sandbox)
      # no-op
      true
    end

    def open(sandbox:, type: :tmux)
      "/terminal/#{sandbox.id}/#{type}"
    end

    def close(sandbox:)
      # no-op
    end
  end
end
