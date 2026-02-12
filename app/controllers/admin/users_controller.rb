module Admin
  class UsersController < ApplicationController
    before_action :set_user, only: %i[edit update destroy]

    def index
      authorize User
      @users = User.includes(:sandboxes).order(:name)
    end

    def new
      authorize User
      @user = User.new
    end

    def create
      authorize User
      @user = User.new(user_params)
      if @user.save
        redirect_to admin_users_path, notice: "User #{@user.name} was created."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
      authorize @user
    end

    def update
      authorize @user
      if @user.update(user_params)
        redirect_to admin_users_path, notice: "User #{@user.name} was updated."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      authorize @user
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
