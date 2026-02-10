class DeviceAuthController < ApplicationController
  def show
    @user_code = params[:code]
  end

  def verify
    user_code = params[:user_code]&.strip&.upcase
    @device_code = DeviceCode.pending.not_expired.find_by(user_code: user_code)

    if @device_code.nil?
      flash.now[:alert] = "Invalid or expired code. Please try again."
      render :show
    else
      render :approve
    end
  end

  def approve
    @device_code = DeviceCode.pending.not_expired.find_by!(id: params[:device_code_id])
    @device_code.approve!(Current.user)

    redirect_to root_path, notice: "Device authorized. You can close this tab and return to your terminal."
  end
end
