module Admin
  class UpdateController < BaseController
    # GET /admin/update/check — force-refresh the update status cache and return JSON
    def check
      result = UpdateChecker.new.force_check
      render json: result
    end

    # POST /admin/update/perform — pull images and spawn the updater container
    def perform
      UpdateManager.new.perform_update!
      render json: { status: "updating" }
    rescue UpdateManager::Error => e
      render json: { error: e.message }, status: :unprocessable_entity
    end
  end
end
