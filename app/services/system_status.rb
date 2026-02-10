class SystemStatus
  DATA_DIR = ENV.fetch("SANDCASTLE_DATA_DIR", "/data")

  def call
    @docker_info_cache = nil
    {
      docker: docker_info,
      sandboxes: sandbox_counts,
      host: host_info
    }
  end

  private

  def cached_docker_info
    @docker_info_cache ||= Docker.info
  end

  def docker_info
    info = cached_docker_info
    {
      version: Docker.version["Version"],
      containers: info["Containers"],
      containers_running: info["ContainersRunning"],
      images: info["Images"],
      runtimes: info["Runtimes"]&.keys
    }
  rescue Docker::Error::DockerError => e
    { error: e.message }
  end

  def host_info
    {
      memory: memory_info,
      disk: disk_info,
      load: load_average,
      cpu_count: cpu_count,
      uptime: uptime_info,
      processes: process_count
    }
  end

  def memory_info
    content = File.read("/proc/meminfo")
    total_kb = extract_meminfo_kb(content, "MemTotal")
    available_kb = extract_meminfo_kb(content, "MemAvailable")
    used_kb = total_kb - available_kb
    {
      total_gb: (total_kb / 1_048_576.0).round(1),
      used_gb: (used_kb / 1_048_576.0).round(1),
      available_gb: (available_kb / 1_048_576.0).round(1),
      percent: ((used_kb.to_f / total_kb) * 100).round(1)
    }
  rescue => e
    { error: e.message }
  end

  def disk_info
    output = `df -B1 #{DATA_DIR} 2>&1`.lines.last
    fields = output.split
    total = fields[1].to_i
    used = fields[2].to_i
    available = fields[3].to_i
    {
      total_gb: (total / 1_073_741_824.0).round(1),
      used_gb: (used / 1_073_741_824.0).round(1),
      available_gb: (available / 1_073_741_824.0).round(1),
      percent: ((used.to_f / total) * 100).round(1)
    }
  rescue => e
    { error: e.message }
  end

  def load_average
    parts = File.read("/proc/loadavg").split
    { one: parts[0].to_f, five: parts[1].to_f, fifteen: parts[2].to_f }
  rescue => e
    { error: e.message }
  end

  def cpu_count
    cached_docker_info["NCPU"]
  rescue => e
    nil
  end

  def uptime_info
    seconds = File.read("/proc/uptime").split.first.to_f.to_i
    days = seconds / 86400
    hours = (seconds % 86400) / 3600
    minutes = (seconds % 3600) / 60
    parts = []
    parts << "#{days}d" if days > 0
    parts << "#{hours}h" if hours > 0 || days > 0
    parts << "#{minutes}m"
    parts.join(" ")
  rescue => e
    nil
  end

  def process_count
    field = File.read("/proc/loadavg").split[3] # e.g. "1/234"
    field.split("/").last.to_i
  rescue => e
    nil
  end

  def extract_meminfo_kb(content, key)
    content[/^#{key}:\s+(\d+)/, 1].to_i
  end

  def sandbox_counts
    {
      total: Sandbox.active.count,
      running: Sandbox.running.count,
      stopped: Sandbox.active.where(status: "stopped").count,
      pending: Sandbox.where(status: "pending").count
    }
  end

  def resource_usage
    running = Sandbox.running.where.not(container_id: nil)
    return {} if running.empty?

    running.map do |sandbox|
      container = Docker::Container.get(sandbox.container_id)
      stats = container.stats(stream: false)
      {
        sandbox: sandbox.full_name,
        cpu_percent: calculate_cpu_percent(stats),
        memory_mb: (stats.dig("memory_stats", "usage") || 0) / 1_048_576.0
      }
    rescue Docker::Error::NotFoundError
      { sandbox: sandbox.full_name, error: "not_found" }
    end
  end

  def calculate_cpu_percent(stats)
    cpu_delta = stats.dig("cpu_stats", "cpu_usage", "total_usage").to_f -
                stats.dig("precpu_stats", "cpu_usage", "total_usage").to_f
    system_delta = stats.dig("cpu_stats", "system_cpu_usage").to_f -
                   stats.dig("precpu_stats", "system_cpu_usage").to_f
    num_cpus = stats.dig("cpu_stats", "online_cpus") || 1

    return 0.0 if system_delta.zero?
    ((cpu_delta / system_delta) * num_cpus * 100.0).round(2)
  end
end
