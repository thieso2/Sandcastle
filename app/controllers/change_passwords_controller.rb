class ChangePasswordsController < ApplicationController
  skip_before_action :require_password_change
  rate_limit to: 10, within: 3.minutes, only: :update, with: -> { redirect_to change_password_path, alert: "Try again later." }

  def show
  end

  def update
    if !Current.user.must_change_password? && !Current.user.authenticate(params[:current_password])
      redirect_to change_password_path, alert: "Current password is incorrect."
    elsif Current.user.update(params.permit(:password, :password_confirmation).merge(must_change_password: false))
      redirect_to root_path, notice: "Password updated."
    else
      redirect_to change_password_path, alert: Current.user.errors.full_messages.to_sentence
    end
  end
end
