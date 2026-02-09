class SystemStatus
  def call
    {
      docker: docker_info,
      sandboxes: sandbox_counts,
      resources: resource_usage
    }
  end

  private

  def docker_info
    info = Docker.info
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
