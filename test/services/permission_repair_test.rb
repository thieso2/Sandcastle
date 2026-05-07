require "test_helper"
require "tmpdir"

class PermissionRepairTest < ActiveSupport::TestCase
  setup do
    @testdir = Dir.mktmpdir("sandcastle-permission-repair-test-")
    @repair_container = ENV[PermissionRepair::REPAIR_CONTAINER_ENV]
    DockerMock.reset!
  end

  teardown do
    if @repair_container.nil?
      ENV.delete(PermissionRepair::REPAIR_CONTAINER_ENV)
    else
      ENV[PermissionRepair::REPAIR_CONTAINER_ENV] = @repair_container
    end
    FileUtils.rm_rf(@testdir)
  end

  test "helper repair containers use host user namespace" do
    PermissionRepair.run(@testdir, "true")

    host_config = DockerMock.created_options.last.fetch("HostConfig")
    assert_equal "host", host_config.fetch("UsernsMode")
    assert_equal "none", host_config.fetch("NetworkMode")
    assert_equal [ "#{@testdir}:/mnt" ], host_config.fetch("Binds")
  end

  test "chown_chmod formats integer mode as octal" do
    PermissionRepair.chown_chmod(@testdir, uid: 123, gid: 456, mode: 0o755)

    command = DockerMock.created_options.last.fetch("Cmd")
    assert_equal [ "sh", "-c", "chown 123:456 /mnt && chmod 755 /mnt" ], command
  end

  test "repairs through the current app container when available" do
    ENV[PermissionRepair::REPAIR_CONTAINER_ENV] = "current-app"
    DockerMock.containers["current-app"] = {
      "Id" => "current-app",
      "Name" => "current-app",
      "State" => { "Status" => "running", "Running" => true, "Pid" => 123 }
    }

    PermissionRepair.chown_chmod(@testdir, uid: 123, gid: 456, mode: 0o755)

    assert_empty DockerMock.created_options
    assert_equal(
      {
        container_id: "current-app",
        cmd: [ "sh", "-c", "chown 123:456 #{@testdir} && chmod 755 #{@testdir}" ],
        opts: { user: "root" }
      },
      DockerMock.exec_calls.last
    )
  end
end
