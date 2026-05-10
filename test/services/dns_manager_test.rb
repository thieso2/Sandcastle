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

    File.define_singleton_method(:write) do |target, content|
      if target == tmp && writes.zero?
        writes += 1
        raise Errno::EACCES, target
      end

      writes += 1
      original_write.call(target, content)
    end

    begin
      @manager.send(:atomic_write, path, "dns config")
    ensure
      File.define_singleton_method(:write, original_write)
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
    assert File.exist?(File.join(dns_dir, "db.#{@manager.suffix}"))
    assert File.exist?(File.join(dns_dir, "hosts"))
  end

  test "publish writes wildcard template and zone records for sandbox dns names" do
    user = users(:one)
    dns_dir = File.join(@testdir, "users", user.name, "dns")

    @manager.define_singleton_method(:dns_dir) { |_u| dns_dir }
    @manager.define_singleton_method(:ensure_dir) { |path| FileUtils.mkdir_p(path) }
    @manager.define_singleton_method(:suffix) { "test-castle" }
    @manager.define_singleton_method(:records_for) do |_u|
      [ DnsManager::Record.new(name: "devbox.alpha.test-castle", ip: "100.64.0.8", sandbox_id: 123) ]
    end
    @manager.define_singleton_method(:skipped_for) { |_u| [] }

    @manager.publish(user: user)

    zone = File.read(File.join(dns_dir, "db.test-castle"))
    hosts = File.read(File.join(dns_dir, "hosts"))
    corefile = File.read(File.join(dns_dir, "Corefile"))
    assert_includes corefile, "reload 2s"
    assert_includes corefile, "template IN A test-castle"
    assert_includes corefile, 'match ^([^.]+\.)?devbox\.alpha\.test\-castle\.$'
    assert_includes corefile, 'answer "{{ .Name }} 15 IN A 100.64.0.8"'
    assert_includes corefile, "template IN ANY test-castle"
    assert_includes corefile, 'match ^(?P<prefix>[^.]+\.)?devbox\.alpha\.test\-castle\.test\-castle\.$'
    assert_includes corefile, 'answer "{{ .Name }} 15 IN CNAME {{ .Group.prefix }}devbox.alpha.test-castle."'
    assert_includes zone, "devbox.alpha IN A 100.64.0.8"
    assert_includes zone, "*.devbox.alpha IN A 100.64.0.8"
    assert_includes hosts, "100.64.0.8 devbox.alpha.test-castle *.devbox.alpha.test-castle"
  end

  test "publish does not add search suffix fallback for external fqdn aliases" do
    user = users(:one)
    dns_dir = File.join(@testdir, "users", user.name, "dns")

    @manager.define_singleton_method(:dns_dir) { |_u| dns_dir }
    @manager.define_singleton_method(:ensure_dir) { |path| FileUtils.mkdir_p(path) }
    @manager.define_singleton_method(:suffix) { "test-castle" }
    @manager.define_singleton_method(:records_for) do |_u|
      [ DnsManager::Record.new(name: "www.example.com", ip: "100.64.0.9", sandbox_id: 123, expand: false) ]
    end
    @manager.define_singleton_method(:skipped_for) { |_u| [] }

    @manager.publish(user: user)

    corefile = File.read(File.join(dns_dir, "Corefile"))
    assert_includes corefile, 'match ^([^.]+\.)?www\.example\.com\.$'
    assert_not_includes corefile, "www\\.example\\.com\\.test\\-castle"
    assert_not_includes corefile, "template IN ANY test-castle"
  end
end
