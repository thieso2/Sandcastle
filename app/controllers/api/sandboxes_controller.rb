module Api
  class SandboxesController < BaseController
    before_action :set_sandbox, only: %i[show destroy start stop connect]

    def index
      sandboxes = current_user.sandboxes.active
      render json: sandboxes.map { |s| sandbox_json(s) }
    end

    def show
      render json: sandbox_json(@sandbox)
    end

    def create
      sandbox = SandboxManager.new.create(
        user: current_user,
        name: params.require(:name),
        image: params[:image] || "sandcastle-sandbox:latest",
        persistent: params[:persistent] || false
      )
      render json: sandbox_json(sandbox), status: :created
    end

    def destroy
      SandboxManager.new.destroy(
        sandbox: @sandbox,
        keep_volume: params[:keep_volume] || false
      )
      render json: { status: "destroyed" }
    end

    def start
      SandboxManager.new.start(sandbox: @sandbox)
      render json: sandbox_json(@sandbox.reload)
    end

    def stop
      SandboxManager.new.stop(sandbox: @sandbox)
      render json: sandbox_json(@sandbox.reload)
    end

    def connect
      info = SandboxManager.new.connect_info(sandbox: @sandbox)
      render json: info
    end

    private

    def set_sandbox
      @sandbox = current_user.sandboxes.active.find(params[:id])
    end

    def sandbox_json(sandbox)
      {
        id: sandbox.id,
        name: sandbox.name,
        full_name: sandbox.full_name,
        status: sandbox.status,
        image: sandbox.image,
        ssh_port: sandbox.ssh_port,
        persistent_volume: sandbox.persistent_volume,
        created_at: sandbox.created_at,
        connect_command: sandbox.connect_command
      }
    end
  end
end
