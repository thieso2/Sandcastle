class DashboardController < ApplicationController
  def index
    if Current.user.admin?
      @sandboxes = Sandbox.active.includes(:user).order(:name)
      @system_status = SystemStatus.new.call
      @users = User.includes(:sandboxes).order(:name)
    else
      @sandboxes = Current.user.sandboxes.active.order(:name)
    end

    @sandbox_stats = fetch_sandbox_stats(@sandboxes.select { |s| s.status == "running" })
  end

  private

  def fetch_sandbox_stats(sandboxes)
    stats = {}
    sandboxes.each do |sandbox|
      next if sandbox.container_id.blank?
      container = Docker::Container.get(sandbox.container_id)
      raw = container.stats(stream: false)
      stats[sandbox.id] = {
        cpu_percent: calculate_cpu_percent(raw),
        memory_mb: (raw.dig("memory_stats", "usage") || 0) / 1_048_576.0,
        memory_limit_mb: (raw.dig("memory_stats", "limit") || 0) / 1_048_576.0
      }
    rescue Docker::Error::DockerError
      stats[sandbox.id] = { cpu_percent: 0, memory_mb: 0, memory_limit_mb: 0 }
    end
    stats
  end

  def calculate_cpu_percent(stats)
    cpu_delta = stats.dig("cpu_stats", "cpu_usage", "total_usage").to_f -
                stats.dig("precpu_stats", "cpu_usage", "total_usage").to_f
    system_delta = stats.dig("cpu_stats", "system_cpu_usage").to_f -
                   stats.dig("precpu_stats", "system_cpu_usage").to_f
    num_cpus = stats.dig("cpu_stats", "online_cpus") || 1

    return 0.0 if system_delta.zero?
    ((cpu_delta / system_delta) * num_cpus * 100.0).round(1)
  end
end
