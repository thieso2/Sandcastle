class SandboxesController < ApplicationController
  before_action :set_sandbox, only: [ :show, :update, :destroy, :start, :stop, :rebuild, :retry, :logs, :metrics, :discover_files, :promote_file ]
  before_action :set_archived_sandbox, only: [ :archive_restore, :purge ]

  def new
    authorize Sandbox
    @snapshots = SandboxManager.new.list_snapshots(user: Current.user)
    @btrfs_available = BtrfsHelper.btrfs?
    @defaults = Current.user
    @projects = Current.user.projects.order(:name)
  end

  def show
    @sandbox_snapshots = SandboxManager.new.list_snapshots(user: Current.user)
                           .select { |s| s[:source_sandbox] == @sandbox.name }
    @routes = @sandbox.routes.order(:created_at)
    @btrfs = BtrfsHelper.btrfs?
  end

  def update
    sandbox_params = params.require(:sandbox).permit(
      :name, :ssh_start_tmux, :mount_home, :docker_enabled,
      :vnc_enabled, :vnc_geometry, :vnc_depth, :smb_enabled
    )

    # Only name may be edited while the sandbox is running; everything else
    # needs a rebuild/restart to take effect, so we reject settings edits to
    # avoid silently-stored-but-ignored values.
    if @sandbox.status == "running" && sandbox_params.except(:name).any?
      redirect_to @sandbox, alert: "Stop the sandbox before editing settings." and return
    end

    if @sandbox.update(sandbox_params)
      notice = sandbox_params.keys == ["name"] ? "Sandbox renamed to #{@sandbox.name}." : "Sandbox settings updated. Changes apply on next rebuild/start."
      redirect_to @sandbox, notice: notice
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

    project = Current.user.projects.find_by(id: params[:project_id].presence)

    image = if from_snapshot_name.present?
      snap = Snapshot.find_by(user: Current.user, name: from_snapshot_name)
      snap&.docker_image || "sc-snap-#{Current.user.name}:#{from_snapshot_name}"
    else
      params[:image].presence || project&.image || SandboxManager::DEFAULT_IMAGE
    end

    project_path = params[:project_path].presence
    mount_home = project.present? ? false : (params[:mount_home] == "1")
    home_path = project.present? ? project.path : params[:home_path].presence
    data_path = project.present? ? project.path : (params[:mount_data] == "1" ? (params[:data_path].presence || ".") : nil)
    project_name = project&.name

    if project_path.present?
      mount_home = false
      home_path = project_path
      data_path = project_path
      project_name = File.basename(project_path)
    end

    # Build sandbox record
    # Note: temporary sandboxes can only be created via CLI
    defaults = Setting.instance
    sandbox = Current.user.sandboxes.build(
      name: params.require(:name),
      status: "pending",
      image: image,
      project_name: project_name,
      mount_home: mount_home,
      home_path: home_path,
      data_path: data_path,
      tailscale: project.present? ? project.tailscale : (params[:tailscale] == "1"),
      vnc_enabled: project.present? ? project.vnc_enabled : (params[:vnc_enabled] != "0"),
      vnc_geometry: project.present? ? project.vnc_geometry : (Sandbox::VNC_GEOMETRIES.include?(params[:vnc_geometry]) ? params[:vnc_geometry] : "1280x900"),
      vnc_depth: project.present? ? project.vnc_depth : (Sandbox::VNC_DEPTHS.include?(params[:vnc_depth].to_i) ? params[:vnc_depth].to_i : 24),
      docker_enabled: project.present? ? project.docker_enabled : (params[:docker_enabled] != "0"),
      smb_enabled: project.present? ? project.smb_enabled : (params[:smb_enabled] == "1"),
      ssh_start_tmux: project.present? ? project.ssh_start_tmux : (params[:ssh_start_tmux] == "1"),
      temporary: false
    )

    if sandbox.save
      # Enqueue async job
      SandboxProvisionJob.perform_later(sandbox_id: sandbox.id)

      # Optimistic redirect - dashboard will update via Turbo
      redirect_to root_path, notice: "Creating sandcastle #{sandbox.name}..."
    else
      @snapshots = SandboxManager.new.list_snapshots(user: Current.user)
      @btrfs_available = BtrfsHelper.btrfs?
      @defaults = Current.user
      @projects = Current.user.projects.order(:name)
      flash.now[:alert] = "Failed to create sandbox: #{sandbox.errors.full_messages.join(', ')}"
      render :new, status: :unprocessable_entity
    end
  rescue => e
    @snapshots = SandboxManager.new.list_snapshots(user: Current.user)
    @btrfs_available = BtrfsHelper.btrfs?
    @defaults = Current.user
    @projects = Current.user.projects.order(:name)
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

    # Turbo-stream reply removes just the archived row so the Archived
    # <details> section stays open. Broadcast from the job will also fire a
    # remove when the sandbox reaches the "destroyed" state — idempotent.
    respond_to do |format|
      format.html { redirect_to root_path, notice: "Permanently deleting sandcastle..." }
      format.turbo_stream { render turbo_stream: turbo_stream.remove("#{helpers.dom_id(@sandbox)}-archived") }
    end
  end

  def purge_all
    archived = Current.user.sandboxes.archived.where(job_status: nil)
    count = archived.count

    streams = archived.map do |sandbox|
      sandbox.start_job("destroying")
      SandboxDestroyJob.perform_later(sandbox_id: sandbox.id, archive: false)
      turbo_stream.remove("#{helpers.dom_id(sandbox)}-archived")
    end

    respond_to do |format|
      format.html { redirect_to root_path, notice: "Permanently deleting #{count} archived sandcastle#{'s' if count != 1}..." }
      format.turbo_stream { render turbo_stream: streams }
    end
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

  def rebuild
    if @sandbox.job_in_progress?
      redirect_to root_path, alert: "Operation already in progress"
      return
    end

    @sandbox.start_job("rebuilding")
    SandboxRebuildJob.perform_later(sandbox_id: @sandbox.id)

    respond_to do |format|
      format.html { redirect_to root_path, notice: "Rebuilding sandcastle #{@sandbox.name}..." }
      format.turbo_stream { render turbo_stream: turbo_stream.replace(@sandbox, partial: "dashboard/sandbox", locals: { sandbox: @sandbox }) }
    end
  end

  def discover_files
    @results = HomeFileDiscovery.new(@sandbox).call
  end

  def promote_file
    path = params[:path].to_s
    action = params[:action_type].to_s
    user = Current.user

    if path.blank?
      redirect_back fallback_location: sandbox_path(@sandbox), alert: "Missing path."
      return
    end

    case action
    when "bind"
      bind_path = File.dirname(path)
      bind_path = path if bind_path == "."
      user.persisted_paths.find_or_create_by!(path: bind_path)
      notice = "Persisting #{bind_path}/ on next sandbox start."
    when "inject"
      content = HomeFileDiscovery.new(@sandbox).fetch_content(path)
      record = user.injected_files.find_or_initialize_by(path: path)
      record.content = content
      record.save!
      notice = "Will inject #{path} on next sandbox start."
    when "ignore"
      user.ignored_paths.find_or_create_by!(path: path)
      notice = "Ignoring #{path}."
    else
      redirect_back fallback_location: sandbox_path(@sandbox), alert: "Unknown action."
      return
    end

    redirect_to sandbox_path(@sandbox, anchor: "discover"), notice: notice
  rescue ActiveRecord::RecordInvalid => e
    redirect_back fallback_location: sandbox_path(@sandbox), alert: e.message
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
