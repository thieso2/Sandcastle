class SandboxesController < ApplicationController
  before_action :set_sandbox, only: [ :destroy, :start, :stop ]

  def new
    authorize Sandbox
    @snapshots = SandboxManager.new.list_snapshots(user: current_user)
  end

  def create
    authorize Sandbox

    image = if params[:snapshot].present?
      "sc-snap-#{current_user.name}:#{params[:snapshot]}"
    else
      params[:image].presence || SandboxManager::DEFAULT_IMAGE
    end

    sandbox = SandboxManager.new.create(
      user: current_user,
      name: params.require(:name),
      image: image,
      persistent: params[:persistent] == "1",
      tailscale: params[:tailscale] == "1",
      mount_home: params[:mount_home] == "1",
      data_path: params[:data_path].presence,
      temporary: params[:temporary] == "1"
    )

    redirect_to root_path, notice: "Sandcastle #{sandbox.name} created successfully"
  rescue ActiveRecord::RecordInvalid => e
    @snapshots = SandboxManager.new.list_snapshots(user: current_user)
    flash.now[:alert] = "Failed to create sandbox: #{e.record.errors.full_messages.join(', ')}"
    render :new, status: :unprocessable_entity
  rescue SandboxManager::Error => e
    @snapshots = SandboxManager.new.list_snapshots(user: current_user)
    flash.now[:alert] = "Failed to create sandbox: #{e.message}"
    render :new, status: :unprocessable_entity
  end

  def destroy
    SandboxManager.new.destroy(sandbox: @sandbox)
    redirect_to root_path, notice: "Sandcastle #{@sandbox.name} destroyed"
  end

  def start
    SandboxManager.new.start(sandbox: @sandbox)
    redirect_to root_path, notice: "Sandcastle #{@sandbox.name} started"
  end

  def stop
    SandboxManager.new.stop(sandbox: @sandbox)
    redirect_to root_path, notice: "Sandcastle #{@sandbox.name} stopped"
  end

  private

  def set_sandbox
    @sandbox = policy_scope(Sandbox).find(params[:id])
    authorize @sandbox
  end
end
