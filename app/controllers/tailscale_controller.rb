class TailscaleController < ApplicationController
  def show
  end

  def update
    Current.user.update!(tailscale_auth_key: params.require(:auth_key))
    redirect_to tailscale_path, notice: "Tailscale auth key saved. New sandboxes created with --tailscale will join your tailnet."
  end

  def update_settings
    Current.user.update!(tailscale_auto_connect: params[:auto_connect] == "1")
    redirect_to tailscale_path, notice: "Settings updated"
  end

  def destroy
    Current.user.update!(tailscale_auth_key: nil, tailscale_auto_connect: false)
    redirect_to tailscale_path, notice: "Tailscale auth key removed"
  end
end
