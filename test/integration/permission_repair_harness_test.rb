require "test_helper"
require "open3"

class PermissionRepairHarnessTest < ActiveSupport::TestCase
  test "real Docker harness validates image permissions and permission repair" do
    skip "set SANDCASTLE_REAL_DOCKER_TESTS=1 to run the real Docker permission harness" unless ENV["SANDCASTLE_REAL_DOCKER_TESTS"] == "1"

    script = Rails.root.join("scripts/permission-repair-harness.sh").to_s
    stdout, stderr, status = Open3.capture3(script)

    assert status.success?, <<~MSG
      permission repair harness failed

      STDOUT:
      #{stdout}

      STDERR:
      #{stderr}
    MSG
  end
end
