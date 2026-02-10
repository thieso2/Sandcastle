module Api
  class SnapshotsController < BaseController
    def index
      snapshots = SandboxManager.new.list_snapshots(user: current_user)
      render json: snapshots
    end

    def destroy
      SandboxManager.new.destroy_snapshot(
        user: current_user,
        name: params[:name],
        sandbox_name: params[:sandbox]
      )
      render json: { status: "deleted" }
    end
  end
end
