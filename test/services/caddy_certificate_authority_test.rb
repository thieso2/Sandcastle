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

      cert = OpenSSL::X509::Certificate.new(pem)
      assert_equal cert.subject.to_s, cert.issuer.to_s
      assert_operator cert.not_after, :>, 9.years.from_now
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
