require "fileutils"
require "set"
require "socket"

class DnsManager
  DATA_DIR = ENV.fetch("SANDCASTLE_DATA_DIR", "/data")
  COREDNS_IMAGE = ENV.fetch("SANDCASTLE_DNS_IMAGE", "coredns/coredns:latest")

  class Error < StandardError; end

  Record = Struct.new(:name, :ip, :sandbox_id, keyword_init: true)
  SkippedRecord = Struct.new(:name, :reason, :sandbox_id, keyword_init: true)

  def self.publish_best_effort(user)
    new.publish(user: user)
  rescue => e
    Rails.logger.warn("DnsManager: DNS publish for #{user.name} failed: #{e.message}")
  end

  def status(user:)
    container = dns_container(user)
    container_running = container&.json&.dig("State", "Running") == true

    {
      suffix: suffix,
      network: user.tailscale_network,
      tailscale_ip: tailscale_ip(user),
      resolver_ip: resolver_ip(user),
      resolver_container_id: container&.id&.[](0..11),
      resolver_running: container_running,
      hosts_path: hosts_path(user),
      zone_path: zone_path(user),
      records: records_for(user).map { |r| { name: r.name, ip: r.ip, sandbox_id: r.sandbox_id } },
      skipped: skipped_for(user).map { |r| { name: r.name, reason: r.reason, sandbox_id: r.sandbox_id } }
    }
  end

  def reconcile_all
    User.where(tailscale_state: "enabled").find_each do |user|
      publish(user: user)
      ensure_resolver(user: user)
    rescue => e
      Rails.logger.error("DnsManager: failed to reconcile DNS for #{user.name}: #{e.message}")
    end
  end

  def publish(user:)
    ensure_dir(dns_dir(user))
    write_corefile(user)
    write_zone(user)
    write_hosts(user)
  rescue => e
    raise Error, "Failed to publish DNS for #{user.name}: #{e.message}"
  end

  def ensure_resolver(user:)
    return nil unless user.tailscale_enabled?
    return nil if user.tailscale_network.blank?

    publish(user: user)
    pull_image

    existing = dns_container(user)
    if existing
      running = existing.json.dig("State", "Running")
      return existing if running

      existing.start
      return existing
    end

    container = Docker::Container.create(
      "Image" => COREDNS_IMAGE,
      "name" => container_name(user),
      "Cmd" => [ "-conf", "/data/Corefile" ],
      "HostConfig" => {
        "NetworkMode" => user.tailscale_network,
        "Binds" => [ "#{dns_dir(user)}:/data:ro" ],
        "RestartPolicy" => { "Name" => "unless-stopped" }
      },
      "Labels" => {
        "sandcastle.dns" => "true",
        "sandcastle.owner" => user.name
      }
    )
    container.start
    container
  rescue Docker::Error::DockerError => e
    raise Error, "Failed to ensure DNS resolver for #{user.name}: #{e.message}"
  end

  def cleanup(user)
    container = dns_container(user)
    return unless container

    container.stop(t: 5) rescue nil
    container.delete(force: true)
  rescue Docker::Error::NotFoundError
    nil
  rescue Docker::Error::DockerError => e
    Rails.logger.warn("DnsManager: failed to cleanup DNS resolver for #{user.name}: #{e.message}")
  end

  def suffix
    name = ENV.fetch("SANDCASTLE_NAME", "").presence || Socket.gethostname
    slug = dns_label(name)
    slug.presence || "sandcastle"
  end

  def hostname_for(sandbox)
    fqdn_for(sandbox)
  end

  private

  def records_for(user)
    records = []
    seen = {}

    dns_sandboxes(user).find_each do |sandbox|
      ip = TailscaleManager.new.sandbox_tailscale_ip(sandbox: sandbox)
      next if ip.blank?

      name = fqdn_for(sandbox)
      next if name.blank?

      if seen.key?(name)
        records.reject! { |r| r.name == name }
        seen[name] = :duplicate
        next
      end

      seen[name] = sandbox.id
      records << Record.new(name: name, ip: ip, sandbox_id: sandbox.id)
    end

    records
  end

  def skipped_for(user)
    skipped = []
    names = Hash.new { |h, k| h[k] = [] }

    dns_sandboxes(user).find_each do |sandbox|
      name = fqdn_for(sandbox)
      if name.blank?
        skipped << SkippedRecord.new(name: sandbox.display_name, reason: "invalid DNS label", sandbox_id: sandbox.id)
        next
      end

      ip = TailscaleManager.new.sandbox_tailscale_ip(sandbox: sandbox)
      if ip.blank?
        skipped << SkippedRecord.new(name: name, reason: "no Tailscale network IP", sandbox_id: sandbox.id)
        next
      end

      names[name] << sandbox.id
    end

    names.each do |name, ids|
      next unless ids.size > 1

      ids.each do |id|
        skipped << SkippedRecord.new(name: name, reason: "duplicate DNS name", sandbox_id: id)
      end
    end

    skipped
  end

  def write_corefile(user)
    template_blocks = published_records_for(user).map { |record| template_block_for(record) }.join
    content = <<~CORE
      #{suffix}:53 {
        reload 2s
      #{template_blocks.chomp}
        file /data/#{zone_file_name} #{suffix}
        errors
        log
      }
    CORE
    atomic_write(corefile_path(user), content)
  end

  def dns_sandboxes(user)
    user.sandboxes.running.where(tailscale: true)
  end

  def write_hosts(user)
    lines = published_records_for(user).map do |record|
      "#{record.ip} #{record.name} *.#{record.name}"
    end
    atomic_write(hosts_path(user), "#{lines.join("\n")}\n")
  end

  def write_zone(user)
    zone_records = published_records_for(user)
    serial = Time.now.utc.strftime("%Y%m%d%H").to_i

    lines = [
      "$ORIGIN #{suffix}.",
      "$TTL 15",
      "@ IN SOA ns.#{suffix}. hostmaster.#{suffix}. ( #{serial} 15 15 60 15 )",
      "@ IN NS ns.#{suffix}.",
      "ns IN A 127.0.0.1"
    ]

    zone_records.each do |record|
      relative = record.name.delete_suffix(".#{suffix}")
      lines << "#{relative} IN A #{record.ip}"
      lines << "*.#{relative} IN A #{record.ip}"
    end

    atomic_write(zone_path(user), "#{lines.join("\n")}\n")
  end

  def published_records_for(user)
    skipped_ids = skipped_for(user).select { |r| r.reason == "duplicate DNS name" }.map(&:sandbox_id).to_set
    records_for(user).reject { |r| skipped_ids.include?(r.sandbox_id) }
  end

  def template_block_for(record)
    escaped_name = Regexp.escape(record.name)
    <<~TEMPLATE.indent(2)
      template IN A #{suffix} {
        match ^([^.]+\\.)?#{escaped_name}\\.$
        answer "{{ .Name }} 15 IN A #{record.ip}"
        fallthrough
      }
    TEMPLATE
  end

  def fqdn_for(sandbox)
    sandbox_label = dns_label(sandbox.name)
    project_label = dns_label(sandbox.project_name.presence || "sandboxes")
    instance_label = suffix

    return nil if sandbox_label.blank? || project_label.blank? || instance_label.blank?

    "#{sandbox_label}.#{project_label}.#{instance_label}"
  end

  def dns_label(value)
    label = value.to_s.downcase.tr("_", "-").gsub(/[^a-z0-9-]+/, "-").gsub(/\A-+|-+\z/, "")
    return nil if label.blank? || label.length > 63
    return nil unless label.match?(/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/)

    label
  end

  def resolver_ip(user)
    container = dns_container(user)
    return nil unless container && user.tailscale_network.present?

    container.json.dig("NetworkSettings", "Networks", user.tailscale_network, "IPAddress")
  rescue Docker::Error::DockerError
    nil
  end

  def tailscale_ip(user)
    return nil if user.tailscale_container_id.blank?

    container = Docker::Container.get(user.tailscale_container_id)
    ip_out = container.exec([ "tailscale", "ip", "--4" ])
    ip_out.first.first&.strip if ip_out.first.any?
  rescue Docker::Error::DockerError
    nil
  end

  def dns_container(user)
    Docker::Container.get(container_name(user))
  rescue Docker::Error::NotFoundError
    nil
  end

  def pull_image
    Docker::Image.get(COREDNS_IMAGE)
  rescue Docker::Error::NotFoundError
    Docker::Image.create("fromImage" => COREDNS_IMAGE)
  end

  def atomic_write(path, content)
    tmp = "#{path}.tmp"
    begin
      File.write(tmp, content)
      File.rename(tmp, path)
    rescue Errno::EACCES
      docker_chown(File.dirname(path))
      File.write(tmp, content)
      File.rename(tmp, path)
    end
  ensure
    File.delete(tmp) if tmp && File.exist?(tmp)
  end

  def ensure_dir(path)
    FileUtils.mkdir_p(path)
  rescue Errno::EACCES
    docker_chown(File.dirname(path))
    FileUtils.mkdir_p(path)
  end

  def docker_chown(path)
    return if system("/usr/bin/sudo", "-n", "/usr/bin/chown", "#{Process.uid}:#{Process.gid}", path, out: File::NULL, err: File::NULL) &&
              system("/usr/bin/sudo", "-n", "/usr/bin/chmod", "755", path, out: File::NULL, err: File::NULL)

    docker_run_fix(path, "sh", "-c", "chown #{Process.uid}:#{Process.gid} /mnt && chmod 755 /mnt")
  end

  def docker_run_fix(host_path, *cmd)
    PermissionRepair.run(host_path, *cmd)
  rescue PermissionRepair::Error => e
    raise Error, "docker_run_fix failed for #{host_path}: #{e.message}"
  end

  def fix_image
    PermissionRepair.fix_image
  rescue PermissionRepair::Error => e
    raise Error, e.message
  end

  def dns_dir(user)
    File.join(DATA_DIR, "users", user.name, "dns")
  end

  def hosts_path(user)
    File.join(dns_dir(user), "hosts")
  end

  def corefile_path(user)
    File.join(dns_dir(user), "Corefile")
  end

  def zone_path(user)
    File.join(dns_dir(user), zone_file_name)
  end

  def zone_file_name
    "db.#{suffix}"
  end

  def container_name(user)
    "sc-dns-#{user.name}"
  end
end
