module Admin
  class UsersController < BaseController
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

    def invite
      authorize User, :create?
      @user = User.new(invite_params.merge(
        password: SecureRandom.base64(32),
        status: "pending_approval"
      ))

      if @user.save
        InviteMailer.invite(@user).deliver_later
        redirect_to admin_users_path, notice: "Invite sent to #{@user.email_address}."
      else
        redirect_to admin_users_path, alert: "Could not invite user: #{@user.errors.full_messages.join(', ')}"
      end
    end

    private

    def set_user
      @user = User.find(params[:id])
    end

    def user_params
      params.expect(user: [ :name, :full_name, :email_address, :password, :password_confirmation, :ssh_public_key, :admin, :status ])
    end

    def invite_params
      params.permit(:name, :email_address)
    end
  end
end
