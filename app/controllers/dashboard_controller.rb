class DashboardController < ApplicationController
  def index
    @sandboxes = policy_scope(Sandbox).includes(:user, :routes).order(:name)
    @archived_sandboxes = Current.user.sandboxes.archived.includes(:routes).order(:name)
    @vnc_active_ids = running_vnc_ids
    @tailscale_ips = tailscale_ips_for(@sandboxes)
  end

  def card
    sandbox = policy_scope(Sandbox).includes(:user, :routes).find(params[:id])
    authorize sandbox
    vnc_active = VncManager.new.active?(sandbox: sandbox)
    tailscale_ip = sandbox.tailscale? ? TailscaleManager.new.sandbox_tailscale_ip(sandbox: sandbox) : nil
    render turbo_stream: turbo_stream.replace(helpers.dom_id(sandbox), partial: "dashboard/sandbox", locals: { sandbox: sandbox, vnc_active: vnc_active, tailscale_ip: tailscale_ip })
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
          cpu_percent: StatsCalculator.cpu_percent(raw),
          memory_mb: StatsCalculator.memory_mb(raw),
          memory_limit_mb: (raw.dig("memory_stats", "limit") || 0) / 1_048_576.0,
          net_rx: net_rx,
          net_tx: net_tx,
          disk_read: disk_read,
          disk_write: disk_write,
          pids: raw.dig("pids_stats", "current") || 0
        }
      end
    end

    respond_to do |format|
      format.html { render partial: "sandbox_stats", locals: { stats: @stats, sandbox: sandbox } }
      format.json { render json: @stats ? { cpu: @stats[:cpu_percent], mem: @stats[:memory_mb].round(1) } : { cpu: nil, mem: nil } }
    end
  rescue ActiveRecord::RecordNotFound
    render partial: "sandbox_stats", locals: { stats: nil, sandbox: nil }
  rescue Docker::Error::DockerError
    render partial: "sandbox_stats", locals: { stats: nil, sandbox: sandbox }
  end

  private

  def running_vnc_ids
    Dir.glob(File.join(VncManager::DYNAMIC_DIR, "vnc-*.yml")).filter_map { |f|
      File.basename(f).match(/\Avnc-(\d+)\.yml\z/)&.[](1)&.to_i
    }.to_set
  rescue
    Set.new
  end

  def tailscale_ips_for(sandboxes)
    ts_sandboxes = sandboxes.select { |s| s.tailscale? && s.container_id.present? }
    return {} if ts_sandboxes.empty?

    all_containers = Docker::Container.all
    container_map = all_containers.each_with_object({}) { |c, h| h[c.id] = c }

    ts_sandboxes.each_with_object({}) do |sandbox, ips|
      container = container_map[sandbox.container_id]
      next unless container
      network = sandbox.user.tailscale_network
      next unless network.present?
      ip = container.info.dig("NetworkSettings", "Networks", network, "IPAddress")
      ips[sandbox.id] = ip if ip.present?
    end
  rescue Docker::Error::DockerError
    {}
  end
end
