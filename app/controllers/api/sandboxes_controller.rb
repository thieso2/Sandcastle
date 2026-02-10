module Api
  class SandboxesController < BaseController
    before_action :set_sandbox, only: %i[show update destroy start stop connect snapshot restore tailscale_connect tailscale_disconnect]

    def index
      sandboxes = current_user.sandboxes.active
      render json: sandboxes.map { |s| sandbox_json(s) }
    end

    def show
      render json: sandbox_json(@sandbox)
    end

    def create
      image = if params[:snapshot].present?
        "sc-snap-#{current_user.name}:#{params[:snapshot]}"
      else
        params[:image] || SandboxManager::DEFAULT_IMAGE
      end

      sandbox = SandboxManager.new.create(
        user: current_user,
        name: params.require(:name),
        image: image,
        persistent: params[:persistent] || false,
        tailscale: params.fetch(:tailscale) { current_user.tailscale_enabled? },
        mount_home: params[:mount_home] || false,
        data_path: params[:data_path],
        temporary: params[:temporary] || false
      )
      render json: sandbox_json(sandbox), status: :created
    end

    def update
      @sandbox.update!(params.permit(:temporary))
      render json: sandbox_json(@sandbox)
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

    def snapshot
      result = SandboxManager.new.snapshot(sandbox: @sandbox, name: params[:name])
      render json: result, status: :created
    end

    def restore
      SandboxManager.new.restore(sandbox: @sandbox, snapshot_name: params.require(:snapshot))
      render json: sandbox_json(@sandbox.reload)
    end

    def tailscale_connect
      TailscaleManager.new.connect_sandbox(sandbox: @sandbox)
      render json: sandbox_json(@sandbox.reload)
    end

    def tailscale_disconnect
      TailscaleManager.new.disconnect_sandbox(sandbox: @sandbox)
      render json: sandbox_json(@sandbox.reload)
    end

    private

    def set_sandbox
      @sandbox = current_user.sandboxes.active.find(params[:id])
    end

    def sandbox_json(sandbox)
      json = {
        id: sandbox.id,
        name: sandbox.name,
        full_name: sandbox.full_name,
        status: sandbox.status,
        image: sandbox.image,
        ssh_port: sandbox.ssh_port,
        persistent_volume: sandbox.persistent_volume,
        mount_home: sandbox.mount_home,
        data_path: sandbox.data_path,
        temporary: sandbox.temporary,
        tailscale: sandbox.tailscale,
        route_domain: sandbox.route_domain,
        route_port: sandbox.route_port,
        route_url: sandbox.route_url,
        created_at: sandbox.created_at,
        connect_command: sandbox.connect_command
      }

      if sandbox.tailscale?
        json[:tailscale_ip] = TailscaleManager.new.sandbox_tailscale_ip(sandbox: sandbox)
      end

      json
    end
  end
end
