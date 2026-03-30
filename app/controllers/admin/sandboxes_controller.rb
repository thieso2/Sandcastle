module Admin
  class SandboxesController < BaseController
    before_action :set_sandbox, except: [ :stats, :archive_restore, :purge ]
    before_action :set_archived_sandbox, only: [ :archive_restore, :purge ]

    def destroy
      authorize @sandbox
      if @sandbox.job_in_progress?
        redirect_to admin_dashboard_path, alert: "Operation already in progress"
        return
      end

      @sandbox.start_job("destroying")
      SandboxDestroyJob.perform_later(sandbox_id: @sandbox.id)

      respond_to do |format|
        format.html { redirect_to admin_dashboard_path, notice: "Destroying sandbox #{@sandbox.name}..." }
        format.turbo_stream { render turbo_stream: turbo_stream.replace(@sandbox, partial: "admin/dashboard/sandbox", locals: { sandbox: @sandbox }) }
      end
    end

    def start
      authorize @sandbox
      if @sandbox.job_in_progress?
        redirect_to admin_dashboard_path, alert: "Operation already in progress"
        return
      end

      @sandbox.start_job("starting")
      SandboxStartJob.perform_later(sandbox_id: @sandbox.id)

      respond_to do |format|
        format.html { redirect_to admin_dashboard_path, notice: "Starting sandbox #{@sandbox.name}..." }
        format.turbo_stream { render turbo_stream: turbo_stream.replace(@sandbox, partial: "admin/dashboard/sandbox", locals: { sandbox: @sandbox }) }
      end
    end

    def stop
      authorize @sandbox
      if @sandbox.job_in_progress?
        redirect_to admin_dashboard_path, alert: "Operation already in progress"
        return
      end

      @sandbox.start_job("stopping")
      SandboxStopJob.perform_later(sandbox_id: @sandbox.id)

      respond_to do |format|
        format.html { redirect_to admin_dashboard_path, notice: "Stopping sandbox #{@sandbox.name}..." }
        format.turbo_stream { render turbo_stream: turbo_stream.replace(@sandbox, partial: "admin/dashboard/sandbox", locals: { sandbox: @sandbox }) }
      end
    end

    def rebuild
      authorize @sandbox
      if @sandbox.job_in_progress?
        redirect_to admin_dashboard_path, alert: "Operation already in progress"
        return
      end

      @sandbox.start_job("rebuilding")
      SandboxRebuildJob.perform_later(sandbox_id: @sandbox.id)

      respond_to do |format|
        format.html { redirect_to admin_dashboard_path, notice: "Rebuilding sandbox #{@sandbox.name}..." }
        format.turbo_stream { render turbo_stream: turbo_stream.replace(@sandbox, partial: "admin/dashboard/sandbox", locals: { sandbox: @sandbox }) }
      end
    end

    def archive_restore
      authorize @sandbox, :archive_restore?
      @sandbox.start_job("restoring")
      SandboxRestoreJob.perform_later(sandbox_id: @sandbox.id)
      redirect_to admin_dashboard_path, notice: "Restoring sandbox #{@sandbox.name}..."
    end

    def purge
      authorize @sandbox, :purge?
      @sandbox.start_job("destroying")
      SandboxDestroyJob.perform_later(sandbox_id: @sandbox.id, archive: false)
      redirect_to admin_dashboard_path, notice: "Purging sandbox #{@sandbox.name}..."
    end

    def stats
      @sandbox = Sandbox.find(params[:id])
      authorize @sandbox
      if @sandbox.status == "running" && @sandbox.container_id.present?
        container = Docker::Container.get(@sandbox.container_id)
        raw = container.stats(stream: false) || {}

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

      render partial: "admin/dashboard/sandbox_stats", locals: { stats: @stats, sandbox: @sandbox }
    rescue ActiveRecord::RecordNotFound
      render partial: "admin/dashboard/sandbox_stats", locals: { stats: nil, sandbox: nil }
    rescue Docker::Error::DockerError
      render partial: "admin/dashboard/sandbox_stats", locals: { stats: nil, sandbox: @sandbox }
    end

    private

    def set_sandbox
      @sandbox = Sandbox.active.find(params[:id])
    end

    def set_archived_sandbox
      @sandbox = Sandbox.archived.find(params[:id])
    end
  end
end
