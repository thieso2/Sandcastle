class SnapshotsController < ApplicationController
  before_action :set_snapshot, only: %i[destroy clone]

  def index
    authorize Snapshot
    @snapshots = SandboxManager.new.list_snapshots(user: Current.user)
  end

  # POST /sandboxes/:id/snapshot
  def create_for_sandbox
    # Member route provides sandbox id as params[:id]
    sandbox = policy_scope(Sandbox).find(params[:id])
    authorize sandbox, :snapshot?

    layers = params[:layers].present? ? Array(params[:layers]) : nil

    SandboxManager.new.create_snapshot(
      sandbox: sandbox,
      name: params.require(:name),
      label: params[:label].presence,
      layers: layers,
      data_subdir: params[:data_subdir].presence
    )

    redirect_to sandbox_path(sandbox), notice: "Snapshot created."
  rescue SandboxManager::Error => e
    redirect_back_or_to root_path, alert: "Failed to create snapshot: #{e.message}"
  end

  def destroy
    SandboxManager.new.destroy_snapshot(user: Current.user, name: params[:name])
    redirect_to snapshots_path, notice: "Snapshot deleted."
  rescue SandboxManager::Error => e
    redirect_to snapshots_path, alert: "Failed to delete snapshot: #{e.message}"
  end

  # POST /snapshots/:name/clone — redirect to new sandbox form pre-filled with snapshot
  def clone
    authorize @snapshot, :show?
    redirect_to new_sandbox_path(snapshot: @snapshot.name)
  end

  private

  def set_snapshot
    @snapshot = Snapshot.find_by!(user: Current.user, name: params[:name])
    authorize @snapshot
  rescue ActiveRecord::RecordNotFound
    SandboxManager.new.import_legacy_snapshots(Current.user)
    @snapshot = Snapshot.find_by!(user: Current.user, name: params[:name])
    authorize @snapshot
  end
end
