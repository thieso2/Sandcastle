module Api
  class SnapshotsController < BaseController
    before_action :set_snapshot, only: %i[show destroy]

    def index
      authorize Snapshot
      snapshots = SandboxManager.new.list_snapshots(user: current_user)
      render json: snapshots
    end

    def create
      authorize Snapshot

      sandbox = policy_scope(Sandbox).find(params.require(:sandbox_id))

      layers = params[:layers].present? ? Array(params[:layers]) : nil

      snap = SandboxManager.new.create_snapshot(
        sandbox: sandbox,
        name: params.require(:name),
        label: params[:label],
        layers: layers,
        data_subdir: params[:data_subdir]
      )

      render json: SandboxManager.new.snapshot_json(snap), status: :created
    end

    def show
      render json: SandboxManager.new.snapshot_json(@snapshot)
    end

    def destroy
      SandboxManager.new.destroy_snapshot(user: current_user, name: params[:name])
      render json: { status: "deleted" }
    end

    private

    def set_snapshot
      @snapshot = policy_scope(Snapshot).find_by!(name: params[:name])
      authorize @snapshot
    rescue ActiveRecord::RecordNotFound
      # Try importing legacy Docker snapshots first
      SandboxManager.new.import_legacy_snapshots(current_user)
      @snapshot = policy_scope(Snapshot).find_by!(name: params[:name])
      authorize @snapshot
    end
  end
end
