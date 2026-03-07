class SandboxesController < ApplicationController
  before_action :set_sandbox, only: [ :show, :update, :destroy, :start, :stop, :retry, :logs, :metrics ]
  before_action :set_archived_sandbox, only: [ :archive_restore, :purge ]

  def new
    authorize Sandbox
    @snapshots = SandboxManager.new.list_snapshots(user: Current.user)
    @btrfs_available = BtrfsHelper.btrfs?
    @defaults = Setting.instance
  end

  def show
    @sandbox_snapshots = SandboxManager.new.list_snapshots(user: Current.user)
                           .select { |s| s[:source_sandbox] == @sandbox.name }
    @routes = @sandbox.routes.order(:created_at)
    @btrfs = BtrfsHelper.btrfs?
  end

  def update
    if @sandbox.update(params.require(:sandbox).permit(:name))
      redirect_to @sandbox, notice: "Sandbox renamed to #{@sandbox.name}."
    else
      @sandbox_snapshots = SandboxManager.new.list_snapshots(user: Current.user)
                             .select { |s| s[:source_sandbox] == @sandbox.name }
      @routes = @sandbox.routes.order(:created_at)
      @btrfs = BtrfsHelper.btrfs?
      flash.now[:alert] = @sandbox.errors.full_messages.join(", ")
      render :show, status: :unprocessable_entity
    end
  end

  def create
    authorize Sandbox

    from_snapshot_name = params[:snapshot].presence

    image = if from_snapshot_name.present?
      snap = Snapshot.find_by(user: Current.user, name: from_snapshot_name)
      snap&.docker_image || "sc-snap-#{Current.user.name}:#{from_snapshot_name}"
    else
      params[:image].presence || SandboxManager::DEFAULT_IMAGE
    end

    # Build sandbox record
    # Note: temporary sandboxes can only be created via CLI
    defaults = Setting.instance
    sandbox = Current.user.sandboxes.build(
      name: params.require(:name),
      status: "pending",
      image: image,
      persistent_volume: params[:persistent] == "1",
      mount_home: params[:mount_home] == "1",
      data_path: params[:data_path].presence,
      tailscale: params[:tailscale] == "1",
      vnc_enabled: params[:vnc_enabled] != "0",
      vnc_geometry: Sandbox::VNC_GEOMETRIES.include?(params[:vnc_geometry]) ? params[:vnc_geometry] : "1280x900",
      vnc_depth: Sandbox::VNC_DEPTHS.include?(params[:vnc_depth].to_i) ? params[:vnc_depth].to_i : 24,
      docker_enabled: params[:docker_enabled] != "0",
      temporary: false
    )

    if sandbox.persistent_volume
      sandbox.volume_path = "#{SandboxManager::DATA_DIR}/sandboxes/#{sandbox.full_name}/vol"
    end

    if sandbox.save
      # Enqueue async job
      SandboxProvisionJob.perform_later(sandbox_id: sandbox.id)

      # Optimistic redirect - dashboard will update via Turbo
      redirect_to root_path, notice: "Creating sandcastle #{sandbox.name}..."
    else
      @snapshots = SandboxManager.new.list_snapshots(user: Current.user)
      flash.now[:alert] = "Failed to create sandbox: #{sandbox.errors.full_messages.join(', ')}"
      render :new, status: :unprocessable_entity
    end
  rescue => e
    @snapshots = SandboxManager.new.list_snapshots(user: Current.user)
    flash.now[:alert] = "Failed to create sandbox: #{e.message}"
    render :new, status: :unprocessable_entity
  end

  def metrics
    points = @sandbox.container_metrics.recent
      .map { |m| { t: m.recorded_at.to_i, cpu: m.cpu_percent, mem: m.memory_mb.round(0) } }

    # Append current live stats so graphs render instantly on page load
    if @sandbox.status == "running" && @sandbox.container_id.present?
      full = Rails.cache.fetch("sandbox_stats_full:#{@sandbox.id}", expires_in: 4.seconds) do
        raw = Docker::Container.get(@sandbox.container_id).stats(stream: false)
        next nil if raw.blank?
        {
          cpu_percent: StatsCalculator.cpu_percent(raw),
          memory_mb: StatsCalculator.memory_mb(raw),
          memory_limit_mb: (raw.dig("memory_stats", "limit") || 0) / 1_048_576.0,
          net_rx: 0, net_tx: 0, disk_read: 0, disk_write: 0, pids: 0
        }
      rescue Docker::Error::DockerError
        nil
      end
      points << { t: Time.current.to_i, cpu: full[:cpu_percent], mem: full[:memory_mb].round(0) } if full
    end

    render json: points
  end

  def logs
    tail = (params[:tail] || 200).to_i.clamp(1, 5000)
    @tail = tail
    @logs = SandboxManager.new.logs(sandbox: @sandbox, tail: tail, timestamps: true)
  rescue SandboxManager::Error => e
    @logs = nil
    @log_error = e.message
  end

  def destroy
    if @sandbox.job_in_progress?
      redirect_to root_path, alert: "Operation already in progress"
      return
    end

    user = Current.user
    archive = user.effective_archive_retention_days > 0

    @sandbox.start_job("destroying")
    SandboxDestroyJob.perform_later(sandbox_id: @sandbox.id, archive: archive)

    notice = archive ? "Archiving sandcastle #{@sandbox.name}..." : "Destroying sandcastle #{@sandbox.name}..."
    respond_to do |format|
      format.html { redirect_to root_path, notice: notice }
      format.turbo_stream { render turbo_stream: turbo_stream.replace(@sandbox, partial: "dashboard/sandbox", locals: { sandbox: @sandbox }) }
    end
  end

  def archive_restore
    if @sandbox.job_in_progress?
      redirect_to root_path, alert: "Operation already in progress"
      return
    end

    @sandbox.start_job("restoring")
    SandboxRestoreJob.perform_later(sandbox_id: @sandbox.id)
    redirect_to root_path, notice: "Restoring sandcastle #{@sandbox.name}..."
  end

  def purge
    authorize @sandbox, :purge?
    if @sandbox.job_in_progress?
      redirect_to root_path, alert: "Operation already in progress"
      return
    end

    @sandbox.start_job("destroying")
    SandboxDestroyJob.perform_later(sandbox_id: @sandbox.id, archive: false)
    redirect_to root_path, notice: "Permanently deleting sandcastle..."
  end

  def start
    if @sandbox.job_in_progress?
      redirect_to root_path, alert: "Operation already in progress"
      return
    end

    @sandbox.start_job("starting")
    SandboxStartJob.perform_later(sandbox_id: @sandbox.id)

    respond_to do |format|
      format.html { redirect_to root_path, notice: "Starting sandcastle #{@sandbox.name}..." }
      format.turbo_stream { render turbo_stream: turbo_stream.replace(@sandbox, partial: "dashboard/sandbox", locals: { sandbox: @sandbox }) }
    end
  end

  def stop
    if @sandbox.job_in_progress?
      redirect_to root_path, alert: "Operation already in progress"
      return
    end

    @sandbox.start_job("stopping")
    SandboxStopJob.perform_later(sandbox_id: @sandbox.id)

    respond_to do |format|
      format.html { redirect_to root_path, notice: "Stopping sandcastle #{@sandbox.name}..." }
      format.turbo_stream { render turbo_stream: turbo_stream.replace(@sandbox, partial: "dashboard/sandbox", locals: { sandbox: @sandbox }) }
    end
  end

  def retry
    return unless @sandbox.job_failed?

    @sandbox.update!(job_error: nil)

    case @sandbox.status
    when "destroyed", "pending"
      redirect_to root_path, alert: "Cannot retry creation. Please create a new sandbox."
    when "stopped"
      SandboxStartJob.perform_later(sandbox_id: @sandbox.id)
      redirect_to root_path, notice: "Retrying start..."
    when "running"
      redirect_to root_path, alert: "Sandbox is already running"
    end
  end

  private

  def set_sandbox
    @sandbox = policy_scope(Sandbox).find(params[:id])
    authorize @sandbox
  end

  def set_archived_sandbox
    @sandbox = Current.user.sandboxes.archived.find(params[:id])
    authorize @sandbox, :archive_restore?
  end
end
