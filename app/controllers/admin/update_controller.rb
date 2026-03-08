module Admin
  class UpdateController < BaseController
    # GET /admin/update/check — force-refresh the update status cache and return JSON
    def check
      result = UpdateChecker.new.force_check
      render json: result
    end

    # POST /admin/update/pull — start pulling images in the background
    #   target: sandbox | app | all (default)
    def pull
      target = params[:target] || "all"
      UpdateManager.new.start_pull(target: target)
      render json: { status: "pulling", target: target }
    end

    # GET /admin/update/status — poll pull progress
    def status
      render json: UpdateManager.new.pull_status
    end

    # POST /admin/update/restart — spawn the updater container that runs docker compose up
    def restart
      UpdateManager.new.restart!
      render json: { status: "restarting" }
    rescue UpdateManager::Error => e
      render json: { error: e.message }, status: :unprocessable_entity
    end

    # GET /admin/update/progress — fullscreen page shown while the app restarts
    def progress
      render layout: false
    end
  end
end
