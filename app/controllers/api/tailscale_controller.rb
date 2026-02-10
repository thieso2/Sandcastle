module Api
  class TailscaleController < BaseController
    def show
      render json: {
        configured: current_user.tailscale_configured?,
        auto_connect: current_user.tailscale_auto_connect?,
        auth_key_set: current_user.tailscale_auth_key.present?
      }
    end

    def update
      current_user.update!(tailscale_auth_key: params.require(:auth_key))
      render json: { configured: true }
    end

    def update_settings
      current_user.update!(tailscale_auto_connect: params[:auto_connect])
      render json: { auto_connect: current_user.tailscale_auto_connect? }
    end

    def destroy
      current_user.update!(tailscale_auth_key: nil, tailscale_auto_connect: false)
      render json: { configured: false }
    end
  end
end
