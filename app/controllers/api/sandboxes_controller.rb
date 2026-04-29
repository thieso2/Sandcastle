module Api
  class SandboxesController < BaseController
    before_action :set_sandbox, only: %i[show update destroy start stop rebuild logs connect snapshot restore tailscale_connect tailscale_disconnect service_start service_stop gcp_oidc_setup gcp_identity]
    before_action :set_archived_sandbox, only: %i[archive_restore purge]

    def index
      authorize Sandbox
      sandboxes = policy_scope(Sandbox)
      render json: sandboxes.map { |s| sandbox_json(s) }
    end

    def archived_index
      authorize Sandbox
      sandboxes = if current_user.admin?
        Sandbox.archived
      else
        current_user.sandboxes.archived
      end.includes(:user, :routes).order(:name)
      render json: sandboxes.map { |s| sandbox_json(s) }
    end

    def show
      render json: sandbox_json(@sandbox)
    end

    def create
      authorize Sandbox

      manager = SandboxManager.new

      # Resolve snapshot for container image
      from_snapshot_name = params[:from_snapshot].presence || params[:snapshot].presence
      restore_layers     = params[:restore_layers].present? ? Array(params[:restore_layers]) : nil

      image = if from_snapshot_name.present?
        # Try to find DB record first
        snap = Snapshot.find_by(user: current_user, name: from_snapshot_name)
        snap&.docker_image || "sc-snap-#{current_user.name}:#{from_snapshot_name}"
      else
        params[:image].presence || SandboxManager::DEFAULT_IMAGE
      end

      # Build sandbox record (fall back to the user's personal defaults where
      # the request doesn't specify a value)
      gcp_oidc_enabled = boolean_param(:gcp_oidc_enabled, false)
      requested_oidc_enabled = boolean_param(:oidc_enabled, current_user.default_oidc_enabled)

      sandbox = current_user.sandboxes.build(
        name: params.require(:name),
        status: "pending",
        image: image,
        mount_home: params.key?(:mount_home) ? params[:mount_home] : current_user.default_mount_home,
        data_path: params.key?(:data_path) ? params[:data_path] : current_user.default_data_path,
        tailscale: params.fetch(:tailscale) { current_user.tailscale_enabled? },
        vnc_enabled: params.key?(:vnc_enabled) ? params[:vnc_enabled] : current_user.default_vnc_enabled,
        vnc_geometry: params[:vnc_geometry] || "1280x900",
        vnc_depth: params[:vnc_depth]&.to_i || 24,
        docker_enabled: params.key?(:docker_enabled) ? params[:docker_enabled] : current_user.default_docker_enabled,
        ssh_start_tmux: params.key?(:ssh_start_tmux) ? params[:ssh_start_tmux] : nil,
        temporary: params[:temporary] || false,
        smb_enabled: params.key?(:smb_enabled) ? params[:smb_enabled] : (current_user.default_smb_enabled && current_user.tailscale_enabled? && current_user.smb_password.present?),
        oidc_enabled: requested_oidc_enabled || gcp_oidc_enabled,
        gcp_oidc_enabled: gcp_oidc_enabled,
        gcp_oidc_config_id: params[:gcp_oidc_config_id],
        gcp_service_account_email: params[:gcp_service_account_email],
        gcp_principal_scope: params[:gcp_principal_scope].presence || "user",
        gcp_roles: parse_gcp_roles(params[:gcp_roles])
      )

      sandbox.save!

      # Restore BTRFS layers from snapshot (if requested and available)
      if from_snapshot_name.present? && snap.present?
        want_home = restore_layers.nil? || restore_layers.include?("home")
        want_data = restore_layers.nil? || restore_layers.include?("data")

        if want_home && snap.home_snapshot.present? && BtrfsHelper.btrfs?
          manager.ensure_mount_dirs(current_user, sandbox)
          home_target = "#{SandboxManager::DATA_DIR}/users/#{current_user.name}/home"
          BtrfsHelper.restore_subvolume(snap.home_snapshot, home_target) rescue nil
        end

        if want_data && snap.data_snapshot.present? && BtrfsHelper.btrfs?
          data_target = if snap.data_subdir.present? && sandbox.data_path.present?
            "#{SandboxManager::DATA_DIR}/users/#{current_user.name}/data/#{sandbox.data_path}/#{snap.data_subdir}".chomp("/")
          elsif sandbox.data_path.present?
            "#{SandboxManager::DATA_DIR}/users/#{current_user.name}/data/#{sandbox.data_path}".chomp("/")
          end
          BtrfsHelper.restore_subvolume(snap.data_snapshot, data_target) rescue nil if data_target
        end
      end

      # Enqueue async job
      SandboxProvisionJob.perform_later(sandbox_id: sandbox.id)

      # Return immediately with job_status so CLI can poll
      render json: sandbox_json(sandbox), status: :created
    end

    def update
      sandbox_params = params.permit(
        :temporary, :name, :oidc_enabled,
        :gcp_oidc_enabled, :gcp_oidc_config_id, :gcp_service_account_email, :gcp_principal_scope
      ).to_h
      sandbox_params[:gcp_roles] = parse_gcp_roles(params[:gcp_roles]) if params.key?(:gcp_roles)

      runtime_keys = sandbox_params.keys - %w[name temporary]
      if @sandbox.status == "running" && runtime_keys.any?
        render json: { error: "Stop the sandbox before editing settings." }, status: :conflict
        return
      end

      @sandbox.update!(sandbox_params)
      render json: sandbox_json(@sandbox)
    end

    def gcp_oidc_setup
      render json: GcpOidcSetup.new(user: @sandbox.user, sandbox: @sandbox).as_json
    end

    def gcp_identity
      if @sandbox.status == "running"
        render json: { error: "Stop the sandbox before editing settings." }, status: :conflict
        return
      end

      @sandbox.update!(gcp_identity_params)
      render json: {
        sandbox: sandbox_json(@sandbox.reload),
        setup: GcpOidcSetup.new(user: @sandbox.user, sandbox: @sandbox).as_json
      }
    end

    def destroy
      if @sandbox.job_in_progress?
        render json: { error: "Operation already in progress" }, status: :conflict
        return
      end

      archive = @sandbox.user.effective_archive_retention_days > 0
      SandboxDestroyJob.perform_later(sandbox_id: @sandbox.id, archive: archive)

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

    def rebuild
      if @sandbox.job_in_progress?
        render json: { error: "Operation already in progress" }, status: :conflict
        return
      end

      SandboxRebuildJob.perform_later(sandbox_id: @sandbox.id)
      render json: sandbox_json(@sandbox.reload)
    end

    def logs
      tail = (params[:tail] || 200).to_i.clamp(1, 5000)
      logs = SandboxManager.new.logs(sandbox: @sandbox, tail: tail, timestamps: params[:timestamps] == "true")
      render json: { logs: logs }
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
      layers = params[:layers].present? ? Array(params[:layers]) : nil
      snap = SandboxManager.new.create_snapshot(
        sandbox: @sandbox,
        name: params[:name],
        label: params[:label],
        layers: layers,
        data_subdir: params[:data_subdir]
      )
      render json: SandboxManager.new.snapshot_json(snap), status: :created
    end

    def restore
      layers = params[:layers].present? ? Array(params[:layers]) : nil
      SandboxManager.new.restore(
        sandbox: @sandbox,
        snapshot_name: params.require(:snapshot),
        layers: layers
      )
      render json: sandbox_json(@sandbox.reload)
    end

    def archive_restore
      @sandbox.start_job("restoring")
      SandboxRestoreJob.perform_later(sandbox_id: @sandbox.id)
      render json: sandbox_json(@sandbox.reload), status: :accepted
    end

    def purge
      @sandbox.start_job("destroying")
      SandboxDestroyJob.perform_later(sandbox_id: @sandbox.id, archive: false)
      render json: { status: "accepted" }, status: :accepted
    end

    def service_start
      service = params[:service]
      SandboxManager.new.service_start(sandbox: @sandbox, service: service)
      if params[:save].present?
        case service
        when "docker" then @sandbox.update!(docker_enabled: true)
        when "vnc" then @sandbox.update!(vnc_enabled: true)
        end
      end
      render json: sandbox_json(@sandbox.reload)
    end

    def service_stop
      service = params[:service]
      SandboxManager.new.service_stop(sandbox: @sandbox, service: service)
      if params[:save].present?
        case service
        when "docker" then @sandbox.update!(docker_enabled: false)
        when "vnc" then @sandbox.update!(vnc_enabled: false)
        end
      end
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
      elsif sandbox.status.in?(%w[destroyed archived])
        raise ActiveRecord::RecordNotFound, "Sandbox with ID #{params[:id]} has been #{sandbox.status}"
      elsif sandbox.user_id != current_user.id
        raise Pundit::NotAuthorizedError, "You don't have access to this sandbox"
      else
        # Sandbox exists and belongs to user, but not in policy scope - this shouldn't happen
        Rails.logger.error("Sandbox #{params[:id]} exists (status: #{sandbox.status}, user: #{sandbox.user_id}) but not in policy_scope for user #{current_user.id}")
        raise ActiveRecord::RecordNotFound, "Sandbox with ID #{params[:id]} is not accessible (status: #{sandbox.status})"
      end
    end

    def set_archived_sandbox
      @sandbox = if current_user.admin?
        Sandbox.archived.find(params[:id])
      else
        current_user.sandboxes.archived.find(params[:id])
      end
      authorize @sandbox, action_name == "purge" ? :purge? : :archive_restore?
    rescue ActiveRecord::RecordNotFound
      raise ActiveRecord::RecordNotFound, "Archived sandbox with ID #{params[:id]} not found"
    end

    def sandbox_json(sandbox)
      json = {
        id: sandbox.id,
        name: sandbox.name,
        full_name: sandbox.full_name,
        status: sandbox.status,
        image: sandbox.image,
        mount_home: sandbox.mount_home,
        data_path: sandbox.data_path,
        temporary: sandbox.temporary,
        tailscale: sandbox.tailscale,
        vnc_enabled: sandbox.vnc_enabled,
        vnc_geometry: sandbox.vnc_geometry,
        vnc_depth: sandbox.vnc_depth,
        docker_enabled: sandbox.docker_enabled,
        smb_enabled: sandbox.smb_enabled,
        oidc_enabled: sandbox.oidc_enabled,
        gcp_oidc_enabled: sandbox.gcp_oidc_enabled,
        gcp_oidc_config_id: sandbox.gcp_oidc_config_id,
        gcp_oidc_config: sandbox.gcp_oidc_config && {
          id: sandbox.gcp_oidc_config.id,
          name: sandbox.gcp_oidc_config.name,
          project_id: sandbox.gcp_oidc_config.project_id,
          project_number: sandbox.gcp_oidc_config.project_number,
          default_service_account_email: sandbox.gcp_oidc_config.default_service_account_email
        },
        gcp_service_account_email: sandbox.gcp_service_account_email,
        effective_gcp_service_account_email: sandbox.effective_gcp_service_account_email,
        gcp_principal_scope: sandbox.gcp_principal_scope,
        gcp_roles: sandbox.gcp_roles_list,
        gcp_oidc_configured: sandbox.gcp_oidc_configured?,
        ssh_start_tmux: sandbox.effective_ssh_start_tmux?,
        routes: sandbox.routes.map { |r| { id: r.id, domain: r.domain, port: r.port, url: r.url } },
        image_version: sandbox.image_version,
        image_built_at: sandbox.image_built_at,
        created_at: sandbox.created_at,
        archived_at: sandbox.archived_at,
        connect_command: sandbox.connect_command,
        job_status: sandbox.job_status,
        job_error: sandbox.job_error
      }

      if sandbox.tailscale?
        json[:tailscale_ip] = TailscaleManager.new.sandbox_tailscale_ip(sandbox: sandbox)
      end

      json
    end

    def gcp_identity_params
      attrs = {}
      attrs[:gcp_oidc_enabled] = boolean_param(:gcp_oidc_enabled, @sandbox.gcp_oidc_enabled?) if params.key?(:gcp_oidc_enabled)
      attrs[:gcp_oidc_config_id] = params[:gcp_oidc_config_id] if params.key?(:gcp_oidc_config_id)
      attrs[:gcp_service_account_email] = params[:gcp_service_account_email] if params.key?(:gcp_service_account_email)
      attrs[:gcp_principal_scope] = params[:gcp_principal_scope].presence || "user" if params.key?(:gcp_principal_scope)
      attrs[:gcp_roles] = parse_gcp_roles(params[:gcp_roles]) if params.key?(:gcp_roles)
      attrs
    end

    def parse_gcp_roles(value)
      Array(value).flat_map { |role| role.to_s.split(/[\n,]/) }
        .map(&:strip)
        .reject(&:blank?)
        .uniq
    end

    def boolean_param(key, default)
      return default unless params.key?(key)

      ActiveModel::Type::Boolean.new.cast(params[key])
    end
  end
end
