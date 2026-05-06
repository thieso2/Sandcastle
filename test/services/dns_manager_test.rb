# frozen_string_literal: true

require "test_helper"

class DnsManagerTest < ActiveSupport::TestCase
  setup do
    @manager = DnsManager.new
    @testdir = Dir.mktmpdir("sandcastle-dns-manager-test-")
    DockerMock.reset!
  end

  teardown do
    FileUtils.rm_rf(@testdir)
  end

  test "atomic_write repairs parent directory and retries when temp file is not writable" do
    path = File.join(@testdir, "Corefile")
    tmp = "#{path}.tmp"
    writes = 0
    repaired_path = nil
    original_write = File.method(:write)

    @manager.define_singleton_method(:docker_chown) do |parent|
      repaired_path = parent
    end

    File.stub(:write, lambda { |target, content|
      if target == tmp && writes.zero?
        writes += 1
        raise Errno::EACCES, target
      end

      writes += 1
      original_write.call(target, content)
    }) do
      @manager.send(:atomic_write, path, "dns config")
    end

    assert_equal @testdir, repaired_path
    assert_equal 2, writes
    assert_equal "dns config", File.read(path)
    assert_not File.exist?(tmp)
  end

  test "publish uses self-healing dns directory creation" do
    user = users(:one)
    dns_dir = File.join(@testdir, "users", user.name, "dns")
    ensured = nil

    @manager.define_singleton_method(:dns_dir) { |_u| dns_dir }
    @manager.define_singleton_method(:ensure_dir) { |path| ensured = path; FileUtils.mkdir_p(path) }
    @manager.define_singleton_method(:records_for) { |_u| [] }
    @manager.define_singleton_method(:skipped_for) { |_u| [] }

    @manager.publish(user: user)

    assert_equal dns_dir, ensured
    assert File.exist?(File.join(dns_dir, "Corefile"))
    assert File.exist?(File.join(dns_dir, "hosts"))
  end
end
