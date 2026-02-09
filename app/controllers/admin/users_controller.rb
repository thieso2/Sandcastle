module Admin
  class UsersController < ApplicationController
    before_action :require_admin!
    before_action :set_user, only: %i[edit update destroy]

    def index
      @users = User.includes(:sandboxes).order(:name)
    end

    def new
      @user = User.new
    end

    def create
      @user = User.new(user_params)
      if @user.save
        redirect_to admin_users_path, notice: "User #{@user.name} was created."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
    end

    def update
      if @user.update(user_params)
        redirect_to admin_users_path, notice: "User #{@user.name} was updated."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      @user.sandboxes.active.each do |sandbox|
        SandboxManager.new.destroy(sandbox: sandbox)
      end
      @user.destroy!
      redirect_to admin_users_path, notice: "User #{@user.name} was deleted."
    end

    private

    def set_user
      @user = User.find(params[:id])
    end

    def user_params
      params.expect(user: [ :name, :email_address, :password, :password_confirmation, :ssh_public_key, :admin, :status ])
    end
  end
end
