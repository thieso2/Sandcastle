module Api
  class UsersController < BaseController
    before_action :set_user, only: %i[show update destroy]

    def index
      authorize User
      users = User.all
      render json: users.map { |u| user_json(u) }
    end

    def show
      render json: user_json(@user, include_sandboxes: true)
    end

    def create
      authorize User
      user = User.create!(user_params)
      render json: user_json(user), status: :created
    end

    def update
      @user.update!(user_params)
      render json: user_json(@user)
    end

    def destroy
      @user.sandboxes.active.each do |sandbox|
        SandboxManager.new.destroy(sandbox: sandbox)
      end
      @user.destroy!
      render json: { status: "deleted" }
    end

    private

    def set_user
      @user = User.find(params[:id])
      authorize @user
    end

    def user_params
      params.permit(:name, :full_name, :email_address, :password, :password_confirmation, :ssh_public_key, :admin, :status)
    end

    def user_json(user, include_sandboxes: false)
      json = {
        id: user.id,
        name: user.name,
        email_address: user.email_address,
        admin: user.admin,
        status: user.status,
        ssh_public_key: user.ssh_public_key.present?,
        sandbox_count: user.sandboxes.active.count,
        created_at: user.created_at
      }
      if include_sandboxes
        json[:sandboxes] = user.sandboxes.active.map do |s|
          { id: s.id, name: s.name, status: s.status, ssh_port: s.ssh_port }
        end
      end
      json
    end
  end
end
