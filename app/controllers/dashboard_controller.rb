class DashboardController < ApplicationController
  def index
    @sandboxes = policy_scope(Sandbox).includes(:user, :routes).order(:name)
  end

  def stats
    sandbox = policy_scope(Sandbox).find(params[:id])
    authorize sandbox, :stats?

    if sandbox.status == "running" && sandbox.container_id.present?
      container = Docker::Container.get(sandbox.container_id)
      raw = container.stats(stream: false)

      # Handle case where container is shutting down and returns nil/incomplete stats
      if raw.present?
        networks = raw["networks"] || {}
        net_rx = networks.values.sum { |n| n["rx_bytes"] || 0 }
        net_tx = networks.values.sum { |n| n["tx_bytes"] || 0 }

        blkio = raw.dig("blkio_stats", "io_service_bytes_recursive") || []
        disk_read = blkio.select { |e| e["op"]&.downcase == "read" }.sum { |e| e["value"] || 0 }
        disk_write = blkio.select { |e| e["op"]&.downcase == "write" }.sum { |e| e["value"] || 0 }

        @stats = {
          cpu_percent: calculate_cpu_percent(raw),
          memory_mb: (raw.dig("memory_stats", "usage") || 0) / 1_048_576.0,
          memory_limit_mb: (raw.dig("memory_stats", "limit") || 0) / 1_048_576.0,
          net_rx: net_rx,
          net_tx: net_tx,
          disk_read: disk_read,
          disk_write: disk_write,
          pids: raw.dig("pids_stats", "current") || 0
        }
      end
    end

    render partial: "sandbox_stats", locals: { stats: @stats, sandbox: sandbox }
  rescue ActiveRecord::RecordNotFound
    render partial: "sandbox_stats", locals: { stats: nil, sandbox: nil }
  rescue Docker::Error::DockerError
    render partial: "sandbox_stats", locals: { stats: nil, sandbox: sandbox }
  end

  private

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
