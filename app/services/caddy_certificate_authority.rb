require "openssl"
require "fileutils"
require "docker"
require "open3"

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
    with_permission_repair do
      FileUtils.mkdir_p(dir, mode: 0o700)
      normalize_permissions!
      File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)

        normalize_permissions!
        unless authority_files_exist? && mkcert_authority_usable?
          FileUtils.rm_f([ key_path, cert_path ])
          generate_authority!
        end

        normalize_permissions!
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

  def authority_files_exist?
    File.exist?(cert_path) && File.exist?(key_path)
  rescue Errno::EACCES, Errno::EPERM
    false
  end

  def normalize_permissions!
    FileUtils.mkdir_p(dir, mode: 0o700)
    FileUtils.chmod(0o700, File.join(data_dir, "certs"))
    FileUtils.chmod(0o700, dir)
    FileUtils.chmod(0o644, key_path) if File.exist?(key_path)
    FileUtils.chmod(0o644, cert_path) if File.exist?(cert_path)
    FileUtils.chmod(0o600, lock_path) if File.exist?(lock_path)
  end

  def mkcert_authority_usable?
    return true unless mkcert_path

    tmp_cert = File.join(dir, ".mkcert-check.#{$$}.pem")
    tmp_key = File.join(dir, ".mkcert-check.#{$$}-key.pem")
    success, = run_mkcert(tmp_cert, tmp_key, "sandcastle-check.local")
    success
  ensure
    FileUtils.rm_f(tmp_cert) if tmp_cert
    FileUtils.rm_f(tmp_key) if tmp_key
  end

  def generate_authority!
    return if generate_mkcert_authority

    generate_openssl_authority
  end

  def generate_mkcert_authority
    return false unless mkcert_path

    tmp_cert = File.join(dir, ".mkcert-bootstrap.#{$$}.pem")
    tmp_key = File.join(dir, ".mkcert-bootstrap.#{$$}-key.pem")
    success, output = run_mkcert(tmp_cert, tmp_key, "sandcastle.local")
    raise Error, "mkcert certificate authority generation failed: #{output}" unless success && authority_files_exist?

    true
  ensure
    FileUtils.rm_f(tmp_cert) if tmp_cert
    FileUtils.rm_f(tmp_key) if tmp_key
  end

  def generate_openssl_authority
    key = OpenSSL::PKey::RSA.new(4096)
    cert = build_certificate(key)

    atomic_write(key_path, key.to_pem, mode: 0o644)
    atomic_write(cert_path, cert.to_pem, mode: 0o644)
  end

  def run_mkcert(cert_file, key_file, *names)
    stdout, stderr, status = Open3.capture3(
      { "CAROOT" => dir },
      mkcert_path,
      "-cert-file", cert_file,
      "-key-file", key_file,
      *names
    )
    [ status.success?, [ stdout, stderr ].join ]
  end

  def mkcert_path
    ENV["PATH"].to_s.split(File::PATH_SEPARATOR)
      .map { |path| File.join(path, "mkcert") }
      .find { |path| File.executable?(path) && !File.directory?(path) }
  end

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
    rescue Errno::EACCES, Errno::EPERM
      raise if repaired

      repaired = true
      repair_permissions!
      retry
    end
  end

  def repair_permissions!
    uid = Process.uid.to_s
    gid = Process.gid.to_s
    if system("/usr/bin/sudo", "-n", "/bin/mkdir", "-p", dir, out: File::NULL, err: File::NULL) &&
       system("/usr/bin/sudo", "-n", "/usr/bin/chown", "-R", "#{uid}:#{gid}", File.join(data_dir, "certs"), out: File::NULL, err: File::NULL) &&
       system("/usr/bin/sudo", "-n", "/usr/bin/chmod", "700", File.join(data_dir, "certs"), dir, out: File::NULL, err: File::NULL)
      return
    end

    docker_repair_permissions(uid, gid)
    return if File.writable?(File.join(data_dir, "certs")) && File.writable?(dir)

    raise Error, "permission repair completed but #{File.join(data_dir, "certs")} is still not writable"
  end

  def docker_repair_permissions(uid, gid)
    PermissionRepair.run(
      data_dir,
      "sh", "-c",
      [
        "mkdir -p /mnt/#{DIR_NAME}",
        "chown -R #{uid}:#{gid} /mnt/certs",
        "chmod 700 /mnt/certs /mnt/#{DIR_NAME}",
        "[ ! -f /mnt/#{DIR_NAME}/#{KEY_FILE} ] || chmod 644 /mnt/#{DIR_NAME}/#{KEY_FILE}",
        "[ ! -f /mnt/#{DIR_NAME}/#{CERT_FILE} ] || chmod 644 /mnt/#{DIR_NAME}/#{CERT_FILE}",
        "[ ! -f /mnt/#{DIR_NAME}/.root-ca.lock ] || chmod 600 /mnt/#{DIR_NAME}/.root-ca.lock"
      ].join(" && ")
    )
  rescue PermissionRepair::Error => e
    raise Error, "failed to repair Caddy certificate authority permissions: #{e.message}"
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
