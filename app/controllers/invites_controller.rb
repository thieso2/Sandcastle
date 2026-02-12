class InvitesController < ApplicationController
  allow_unauthenticated_access
  before_action :set_user_by_token

  def edit
  end

  def update
    if @user.update(params.permit(:password, :password_confirmation))
      @user.update!(status: "active")
      start_new_session_for(@user)
      redirect_to root_path, notice: "Welcome to Sandcastle! Your account is now active."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def set_user_by_token
    @user = User.find_by_token_for(:invite, params[:token])
    unless @user
      redirect_to new_session_path, alert: "Invite link is invalid or has expired."
    end
  end
end
