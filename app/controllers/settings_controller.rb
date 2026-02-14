class SettingsController < ApplicationController
  def show
    @user = Current.user
    @api_token = @user.api_tokens.active.first
  end

  def update_profile
    @user = Current.user

    if @user.update(profile_params)
      redirect_to settings_path, notice: "Profile updated successfully."
    else
      render :show, status: :unprocessable_entity
    end
  end

  def update_password
    @user = Current.user

    unless @user.authenticate(params[:current_password])
      redirect_to settings_path, alert: "Current password is incorrect."
      return
    end

    if @user.update(password_params)
      redirect_to settings_path, notice: "Password changed successfully."
    else
      redirect_to settings_path, alert: @user.errors.full_messages.join(", ")
    end
  end

  def toggle_tailscale
    @user = Current.user

    if @user.update(tailscale_auto_connect: !@user.tailscale_auto_connect)
      status = @user.tailscale_auto_connect ? "enabled" : "disabled"
      redirect_to settings_path, notice: "Tailscale auto-connect #{status}."
    else
      redirect_to settings_path, alert: "Failed to update Tailscale settings."
    end
  end

  def generate_token
    @user = Current.user

    # Revoke existing token if present
    @user.api_tokens.active.destroy_all

    token, raw_token = ApiToken.generate_for(@user, name: "Web UI Token")

    flash[:api_token] = raw_token
    redirect_to settings_path, notice: "API token generated. Make sure to copy it now - you won't be able to see it again!"
  end

  def revoke_token
    @user = Current.user
    @user.api_tokens.active.destroy_all

    redirect_to settings_path, notice: "API token revoked."
  end

  private

  def profile_params
    params.require(:user).permit(:email_address)
  end

  def password_params
    params.require(:user).permit(:password, :password_confirmation)
  end
end
