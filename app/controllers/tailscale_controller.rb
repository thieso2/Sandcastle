class TailscaleController < ApplicationController
  def show
    if Current.user.tailscale_enabled?
      @status = TailscaleManager.new.status(user: Current.user)
    elsif Current.user.tailscale_pending?
      @pending = true
    end
  rescue TailscaleManager::Error => e
    @error = e.message
  end

  def login
    tag = params[:tailscale_tag].presence
    Rails.cache.write("ts_tag:#{Current.user.id}", tag, expires_in: 10.minutes) if tag
    hostname = params[:tailscale_hostname].presence
    Rails.cache.write("ts_hostname:#{Current.user.id}", hostname, expires_in: 10.minutes) if hostname

    Current.user.update!(tailscale_state: "pending")
    TailscaleLoginJob.perform_later(user_id: Current.user.id)
    redirect_to tailscale_path, status: :see_other
  end

  def connected
    flash[:notice] = "Tailscale is now connected!"
    redirect_to root_path
  end

  def login_status
    user = Current.user

    # Job hasn't created the container yet
    if user.tailscale_pending? && user.tailscale_container_id.blank?
      error = Rails.cache.read("ts_login_error:#{user.id}")
      if error
        Rails.cache.delete("ts_login_error:#{user.id}")
        user.update!(tailscale_state: "disabled")
        return render json: { status: "error", error: error }, status: :unprocessable_entity
      end
      return render json: { status: "starting", message: "Starting sidecar container..." }
    end

    result = TailscaleManager.new.check_login(user: user)
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
