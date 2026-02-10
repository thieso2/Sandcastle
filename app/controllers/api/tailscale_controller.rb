module Api
  class TailscaleController < BaseController
    def enable
      TailscaleManager.new.enable(
        user: current_user,
        auth_key: params.require(:auth_key)
      )
      render json: { status: "enabled" }, status: :created
    end

    def disable
      TailscaleManager.new.disable(user: current_user)
      render json: { status: "disabled" }
    end

    def status
      result = TailscaleManager.new.status(user: current_user)
      render json: result
    end
  end
end
