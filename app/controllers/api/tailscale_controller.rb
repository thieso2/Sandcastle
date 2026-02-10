module Api
  class TailscaleController < BaseController
    # Legacy: enable with auth key
    def enable
      TailscaleManager.new.enable(
        user: current_user,
        auth_key: params.require(:auth_key)
      )
      render json: { status: "enabled" }, status: :created
    end

    # Phase 1: start sidecar, return login URL
    def login
      result = TailscaleManager.new.start_login(user: current_user)
      render json: result, status: :created
    end

    # Phase 2: poll for auth completion
    def login_status
      result = TailscaleManager.new.check_login(user: current_user)
      render json: result
    end

    def update_settings
      current_user.update!(tailscale_auto_connect: params[:auto_connect])
      render json: { auto_connect: current_user.tailscale_auto_connect? }
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
