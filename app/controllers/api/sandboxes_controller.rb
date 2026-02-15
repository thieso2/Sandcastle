module Api
  class SandboxesController < BaseController
    before_action :set_sandbox, only: %i[show update destroy start stop connect snapshot restore tailscale_connect tailscale_disconnect]

    def index
      authorize Sandbox
      sandboxes = policy_scope(Sandbox)
      render json: sandboxes.map { |s| sandbox_json(s) }
    end

    def show
      render json: sandbox_json(@sandbox)
    end

    def create
      authorize Sandbox
      image = if params[:snapshot].present?
        "sc-snap-#{current_user.name}:#{params[:snapshot]}"
      else
        params[:image] || SandboxManager::DEFAULT_IMAGE
      end

      # Build sandbox record
      sandbox = current_user.sandboxes.build(
        name: params.require(:name),
        status: "pending",
        image: image,
        persistent_volume: params[:persistent] || false,
        mount_home: params[:mount_home] || false,
        data_path: params[:data_path],
        tailscale: params.fetch(:tailscale) { current_user.tailscale_enabled? },
        temporary: params[:temporary] || false
      )

      if sandbox.persistent_volume
        sandbox.volume_path = "#{SandboxManager::DATA_DIR}/sandboxes/#{sandbox.full_name}/vol"
      end

      sandbox.save!

      # Enqueue async job
      SandboxProvisionJob.perform_later(sandbox_id: sandbox.id)

      # Return immediately with job_status so CLI can poll
      render json: sandbox_json(sandbox), status: :created
    end

    def update
      @sandbox.update!(params.permit(:temporary))
      render json: sandbox_json(@sandbox)
    end

    def destroy
      if @sandbox.job_in_progress?
        render json: { error: "Operation already in progress" }, status: :conflict
        return
      end

      # Enqueue async job
      SandboxDestroyJob.perform_later(sandbox_id: @sandbox.id)

      # Return immediately with job_status so CLI can poll
      render json: sandbox_json(@sandbox.reload)
    end

    def start
      if @sandbox.job_in_progress?
        render json: { error: "Operation already in progress" }, status: :conflict
        return
      end

      SandboxStartJob.perform_later(sandbox_id: @sandbox.id)
      render json: sandbox_json(@sandbox.reload)
    end

    def stop
      if @sandbox.job_in_progress?
        render json: { error: "Operation already in progress" }, status: :conflict
        return
      end

      SandboxStopJob.perform_later(sandbox_id: @sandbox.id)
      render json: sandbox_json(@sandbox.reload)
    end

    def connect
      # Allow pending sandboxes to return connect info (they may still be provisioning)
      info = SandboxManager.new.connect_info(sandbox: @sandbox)
      render json: info
    rescue SandboxManager::Error => e
      # If sandbox isn't ready yet, return helpful error
      if @sandbox.status == "pending"
        render json: {
          error: "Sandbox is still being provisioned",
          status: @sandbox.status,
          job_status: @sandbox.job_status
        }, status: :accepted
      else
        raise
      end
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
      @sandbox = policy_scope(Sandbox).find(params[:id])
      authorize @sandbox
    rescue ActiveRecord::RecordNotFound
      # Check if sandbox exists but is out of scope (destroyed or wrong user)
      sandbox = Sandbox.find_by(id: params[:id])
      if sandbox.nil?
        raise ActiveRecord::RecordNotFound, "Sandbox with ID #{params[:id]} not found"
      elsif sandbox.status == "destroyed"
        raise ActiveRecord::RecordNotFound, "Sandbox with ID #{params[:id]} has been destroyed"
      elsif sandbox.user_id != current_user.id && !current_user.admin?
        raise Pundit::NotAuthorizedError, "You don't have access to this sandbox"
      else
        # Sandbox exists and belongs to user, but not in policy scope - this shouldn't happen
        Rails.logger.error("Sandbox #{params[:id]} exists (status: #{sandbox.status}, user: #{sandbox.user_id}) but not in policy_scope for user #{current_user.id} (admin: #{current_user.admin?})")
        raise ActiveRecord::RecordNotFound, "Sandbox with ID #{params[:id]} is not accessible (status: #{sandbox.status})"
      end
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
        routes: sandbox.routes.map { |r| { id: r.id, domain: r.domain, port: r.port, url: r.url } },
        created_at: sandbox.created_at,
        connect_command: sandbox.connect_command,
        job_status: sandbox.job_status,
        job_error: sandbox.job_error
      }

      if sandbox.tailscale?
        json[:tailscale_ip] = TailscaleManager.new.sandbox_tailscale_ip(sandbox: sandbox)
      end

      json
    end
  end
end
