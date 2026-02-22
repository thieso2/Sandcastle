ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "mocha/minitest"
require_relative "test_helpers/session_test_helper"
require_relative "test_helpers/api_test_helper"
require_relative "support/docker_mock"
require_relative "support/tailscale_mock"
require_relative "support/vnc_mock"
require_relative "support/terminal_mock"

# Enable Docker mock for all tests
DockerMock.enable!
TailscaleMock.enable!
VncMock.enable!
TerminalMock.enable!

module ActiveSupport
  class TestCase
    # Disable parallelism: pg 1.6.x segfaults on macOS arm64 / Ruby 4.0 when
    # forking (SSL state), and thread mode races on shared connections during
    # fixture loading.  Tests are fast enough to run sequentially.
    parallelize(workers: 1)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...
  end
end
