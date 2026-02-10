class TailscaleController < ApplicationController
  def show
    if Current.user.tailscale_enabled?
      @status = TailscaleManager.new.status(user: Current.user)
    end
  rescue TailscaleManager::Error => e
    @error = e.message
  end

  def enable
    TailscaleManager.new.enable(
      user: Current.user,
      auth_key: params.require(:auth_key)
    )
    redirect_to tailscale_path, notice: "Tailscale enabled"
  rescue TailscaleManager::Error => e
    redirect_to tailscale_path, alert: e.message
  end

  def disable
    TailscaleManager.new.disable(user: Current.user)
    redirect_to tailscale_path, notice: "Tailscale disabled"
  rescue TailscaleManager::Error => e
    redirect_to tailscale_path, alert: e.message
  end
end
