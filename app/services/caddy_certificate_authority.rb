require "openssl"
require "fileutils"
require "docker"

class CaddyCertificateAuthority
  DIR_NAME = "certs/caddy".freeze
  CERT_FILE = "rootCA.pem".freeze
  KEY_FILE = "rootCA-key.pem".freeze

  class Error < StandardError; end

  def self.ensure!
    new.ensure!
  end

  def self.root_certificate_pem
    new.root_certificate_pem
  end

  def self.dir
    new.dir
  end

  def initialize(data_dir: SandboxManager::DATA_DIR)
    @data_dir = data_dir
  end

  def ensure!
    return if File.exist?(cert_path) && File.exist?(key_path)

    with_permission_repair do
      FileUtils.mkdir_p(dir, mode: 0o700)
      FileUtils.chmod(0o700, dir)
      File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        return true if File.exist?(cert_path) && File.exist?(key_path)

        key = OpenSSL::PKey::RSA.new(4096)
        cert = build_certificate(key)

        atomic_write(key_path, key.to_pem, mode: 0o600)
        atomic_write(cert_path, cert.to_pem, mode: 0o644)
      end
    end
    true
  rescue OpenSSL::OpenSSLError, SystemCallError, Docker::Error::DockerError, Error => e
    raise Error, "failed to prepare Caddy certificate authority: #{e.message}"
  end

  def root_certificate_pem
    ensure!
    File.read(cert_path)
  rescue SystemCallError => e
    raise Error, "failed to read Caddy certificate authority: #{e.message}"
  end

  def dir
    File.join(@data_dir, DIR_NAME)
  end

  private

  attr_reader :data_dir

  def cert_path = File.join(dir, CERT_FILE)
  def key_path = File.join(dir, KEY_FILE)
  def lock_path = File.join(dir, ".root-ca.lock")

  def build_certificate(key)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = SecureRandom.random_number(2**128)
    cert.subject = OpenSSL::X509::Name.parse("/O=Sandcastle development CA/CN=Sandcastle Caddy Root CA")
    cert.issuer = cert.subject
    cert.public_key = key.public_key
    cert.not_before = Time.current
    cert.not_after = 10.years.from_now

    extension_factory = OpenSSL::X509::ExtensionFactory.new
    extension_factory.subject_certificate = cert
    extension_factory.issuer_certificate = cert
    cert.add_extension(extension_factory.create_extension("basicConstraints", "CA:TRUE", true))
    cert.add_extension(extension_factory.create_extension("keyUsage", "keyCertSign, cRLSign", true))
    cert.add_extension(extension_factory.create_extension("subjectKeyIdentifier", "hash"))
    cert.add_extension(extension_factory.create_extension("authorityKeyIdentifier", "keyid:always,issuer:always"))
    cert.sign(key, OpenSSL::Digest::SHA256.new)
    cert
  end

  def with_permission_repair
    repaired = false
    begin
      yield
    rescue Errno::EACCES
      raise if repaired

      repaired = true
      repair_permissions!
      retry
    end
  end

  def repair_permissions!
    uid = Process.uid.to_s
    gid = Process.gid.to_s
    if system("/usr/bin/sudo", "-n", "/bin/mkdir", "-p", dir) &&
       system("/usr/bin/sudo", "-n", "/usr/bin/chown", "-R", "#{uid}:#{gid}", File.join(data_dir, "certs")) &&
       system("/usr/bin/sudo", "-n", "/usr/bin/chmod", "700", File.join(data_dir, "certs"), dir)
      return
    end

    docker_repair_permissions(uid, gid)
  end

  def docker_repair_permissions(uid, gid)
    image = fix_image
    container = Docker::Container.create(
      "Image" => image,
      "Cmd" => [
        "sh", "-c",
        "mkdir -p /mnt/#{DIR_NAME} && chown -R #{uid}:#{gid} /mnt/certs && chmod 700 /mnt/certs /mnt/#{DIR_NAME}"
      ],
      "HostConfig" => { "Binds" => [ "#{data_dir}:/mnt" ] }
    )
    container.start
    result = container.wait(30)
    exit_code = result&.dig("StatusCode") || -1
    raise Error, "failed to repair Caddy certificate authority permissions (exit #{exit_code})" unless exit_code == 0
  ensure
    container&.delete(force: true) rescue nil
  end

  def fix_image
    %w[busybox:latest alpine:latest].each do |image|
      return image if Docker::Image.get(image)
    rescue Docker::Error::DockerError
      next
    end

    image = Docker::Image.all.first
    raise Error, "failed to repair Caddy certificate authority permissions: no local Docker images available" unless image

    image.info["RepoTags"]&.first || image.id
  end

  def atomic_write(path, contents, mode:)
    tmp = "#{path}.#{$$}.tmp"
    File.write(tmp, contents, mode: "w", perm: mode)
    FileUtils.chmod(mode, tmp)
    File.rename(tmp, path)
  ensure
    FileUtils.rm_f(tmp) if tmp && File.exist?(tmp)
  end
end
