require "test_helper"
require "tmpdir"

class CaddyCertificateAuthorityTest < ActiveSupport::TestCase
  test "ensure creates a reusable root certificate and key" do
    Dir.mktmpdir do |dir|
      authority = CaddyCertificateAuthority.new(data_dir: dir)

      assert authority.ensure!
      pem = authority.root_certificate_pem

      assert_includes pem, "BEGIN CERTIFICATE"
      assert_path_exists File.join(dir, "certs/caddy/rootCA.pem")
      assert_path_exists File.join(dir, "certs/caddy/rootCA-key.pem")
      assert_path_exists File.join(dir, "certs/caddy/.root-ca.lock")
      assert_equal 0o644, File.stat(File.join(dir, "certs/caddy/rootCA-key.pem")).mode & 0o777

      cert = OpenSSL::X509::Certificate.new(pem)
      assert_equal cert.subject.to_s, cert.issuer.to_s
      assert_operator cert.not_after, :>, 9.years.from_now
    end
  end

  test "ensure normalizes existing certificate authority permissions" do
    Dir.mktmpdir do |dir|
      authority = CaddyCertificateAuthority.new(data_dir: dir)
      authority.ensure!

      FileUtils.chmod(0o755, File.join(dir, "certs"))
      FileUtils.chmod(0o755, File.join(dir, "certs/caddy"))
      FileUtils.chmod(0o600, File.join(dir, "certs/caddy/rootCA-key.pem"))
      FileUtils.chmod(0o600, File.join(dir, "certs/caddy/rootCA.pem"))
      FileUtils.chmod(0o644, File.join(dir, "certs/caddy/.root-ca.lock"))

      assert authority.ensure!

      assert_equal 0o700, File.stat(File.join(dir, "certs")).mode & 0o777
      assert_equal 0o700, File.stat(File.join(dir, "certs/caddy")).mode & 0o777
      assert_equal 0o644, File.stat(File.join(dir, "certs/caddy/rootCA-key.pem")).mode & 0o777
      assert_equal 0o644, File.stat(File.join(dir, "certs/caddy/rootCA.pem")).mode & 0o777
      assert_equal 0o600, File.stat(File.join(dir, "certs/caddy/.root-ca.lock")).mode & 0o777
    end
  end

  test "ensure regenerates certificate authority files mkcert cannot read" do
    Dir.mktmpdir do |dir|
      authority_dir = File.join(dir, "certs/caddy")
      FileUtils.mkdir_p(authority_dir)
      File.write(File.join(authority_dir, "rootCA.pem"), "bad cert")
      File.write(File.join(authority_dir, "rootCA-key.pem"), "bad key")

      authority = CaddyCertificateAuthority.new(data_dir: dir)
      calls = 0
      authority.define_singleton_method(:mkcert_path) { "/usr/bin/mkcert" }
      authority.define_singleton_method(:run_mkcert) do |cert_file, key_file, *_names|
        calls += 1
        if calls == 1
          [ false, "unexpected content" ]
        else
          File.write(File.join(authority_dir, "rootCA.pem"), "mkcert cert")
          File.write(File.join(authority_dir, "rootCA-key.pem"), "mkcert key")
          File.write(cert_file, "leaf cert")
          File.write(key_file, "leaf key")
          [ true, "" ]
        end
      end

      assert authority.ensure!
      assert_equal "mkcert cert", File.read(File.join(authority_dir, "rootCA.pem"))
      assert_equal "mkcert key", File.read(File.join(authority_dir, "rootCA-key.pem"))
      assert_equal 2, calls
    end
  end

  test "ensure wraps filesystem permission failures" do
    authority = CaddyCertificateAuthority.new(data_dir: "/proc/sandcastle-nope")

    error = assert_raises(CaddyCertificateAuthority::Error) do
      authority.ensure!
    end

    assert_includes error.message, "failed to prepare Caddy certificate authority"
  end

  test "permission repair retries operation-not-permitted failures" do
    authority = CaddyCertificateAuthority.new(data_dir: "/tmp/sandcastle-caddy-test")
    attempts = 0
    repairs = 0

    authority.define_singleton_method(:repair_permissions!) { repairs += 1 }

    result = authority.send(:with_permission_repair) do
      attempts += 1
      raise Errno::EPERM, "chmod" if attempts == 1

      :repaired
    end

    assert_equal :repaired, result
    assert_equal 2, attempts
    assert_equal 1, repairs
  end
end
