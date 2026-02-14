class SandboxesController < ApplicationController
  before_action :set_sandbox, only: [ :destroy, :start, :stop, :retry ]

  def new
    authorize Sandbox
    @snapshots = SandboxManager.new.list_snapshots(user: Current.user)
  end

  def create
    authorize Sandbox

    image = if params[:snapshot].present?
      "sc-snap-#{Current.user.name}:#{params[:snapshot]}"
    else
      params[:image].presence || SandboxManager::DEFAULT_IMAGE
    end

    # Build sandbox record
    # Note: temporary sandboxes can only be created via CLI
    sandbox = Current.user.sandboxes.build(
      name: params.require(:name),
      status: "pending",
      image: image,
      persistent_volume: params[:persistent] == "1",
      mount_home: params[:mount_home] == "1",
      data_path: params[:data_path].presence,
      tailscale: params[:tailscale] == "1",
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

  def destroy
    if @sandbox.job_in_progress?
      redirect_to root_path, alert: "Operation already in progress"
      return
    end

    @sandbox.start_job("destroying")
    SandboxDestroyJob.perform_later(sandbox_id: @sandbox.id)

    respond_to do |format|
      format.html { redirect_to root_path, notice: "Destroying sandcastle #{@sandbox.name}..." }
      format.turbo_stream { render turbo_stream: turbo_stream.replace(@sandbox, partial: "dashboard/sandbox", locals: { sandbox: @sandbox }) }
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
end
