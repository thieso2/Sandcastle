class RegistrationsController < ApplicationController
  allow_unauthenticated_access
  before_action :set_invite

  def new
    @user = User.new(email_address: @invite.email)
  end

  def create
    @user = User.new(registration_params)
    @user.email_address = @invite.email

    if @user.save
      @invite.accept!
      start_new_session_for(@user)
      redirect_to root_path, notice: "Welcome to Sandcastle! Your account is now active."
    else
      render :new, status: :unprocessable_entity
    end
  end

  private

  def set_invite
    @invite = Invite.find_by(token: params[:token])

    unless @invite
      redirect_to new_session_path, alert: "Invite link is invalid."
      return
    end

    if @invite.accepted?
      redirect_to new_session_path, alert: "This invite has already been used."
      return
    end

    if @invite.expired?
      redirect_to new_session_path, alert: "This invite has expired."
    end
  end

  def registration_params
    params.expect(user: [ :name, :full_name, :password, :password_confirmation, :ssh_public_key ])
  end
end
