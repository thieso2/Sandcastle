class TailscaleController < ApplicationController
  def show
    if Current.user.tailscale_enabled?
      @status = TailscaleManager.new.status(user: Current.user)
    elsif Current.user.tailscale_pending?
      @pending = true
      result = TailscaleManager.new.check_login(user: Current.user)
      if result[:status] == "authenticated"
        redirect_to tailscale_path, notice: "Tailscale connected"
        return
      end
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

  def login
    result = TailscaleManager.new.start_login(user: Current.user)
    flash[:login_url] = result[:login_url]
    redirect_to tailscale_path, notice: "Open the Tailscale login link to authenticate."
  rescue TailscaleManager::Error => e
    redirect_to tailscale_path, alert: e.message
  end

  def login_status
    result = TailscaleManager.new.check_login(user: Current.user)
    render json: result
  rescue TailscaleManager::Error => e
    render json: { status: "error", error: e.message }, status: :unprocessable_entity
  end

  def update_settings
    Current.user.update!(tailscale_auto_connect: params[:auto_connect] == "1")
    redirect_to tailscale_path, notice: "Settings updated"
  end

  def disable
    TailscaleManager.new.disable(user: Current.user)
    redirect_to tailscale_path, notice: "Tailscale disabled"
  rescue TailscaleManager::Error => e
    redirect_to tailscale_path, alert: e.message
  end
end
