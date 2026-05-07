class SandboxCertificateRefreshJob < ApplicationJob
  queue_as :default

  def perform(_sandbox_id = nil)
    return unless ENV["SANDCASTLE_TLS_MODE"] == "mkcert"

    cert_dir = File.join(RouteManager::DATA_DIR, "traefik", "certs")
    fingerprint_path = File.join(cert_dir, "cert.fingerprint")

    rm = RouteManager.new
    host = ENV.fetch("SANDCASTLE_HOST", "localhost")
    desired_sans = rm.send(:mkcert_san_list, host)
    desired_fp = Digest::SHA256.hexdigest(desired_sans.join("\n"))

    on_disk_fp = File.exist?(fingerprint_path) ? File.read(fingerprint_path).strip : nil
    return if on_disk_fp == desired_fp

    Rails.logger.info("SandboxCertificateRefreshJob: SAN list changed (#{desired_sans.size} SANs), regenerating mkcert cert")

    [ "cert.pem", "key.pem", "cert.fingerprint" ].each do |name|
      path = File.join(cert_dir, name)
      File.delete(path) if File.exist?(path)
    end

    rm.write_rails_config(host: host)
  rescue => e
    Rails.logger.error("SandboxCertificateRefreshJob failed: #{e.class}: #{e.message}")
  end
end
