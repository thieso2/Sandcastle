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

      cert = OpenSSL::X509::Certificate.new(pem)
      assert_equal cert.subject.to_s, cert.issuer.to_s
      assert_operator cert.not_after, :>, 9.years.from_now
    end
  end
end
