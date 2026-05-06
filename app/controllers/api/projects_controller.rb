module Api
  class ProjectsController < BaseController
    before_action :set_project, only: %i[show destroy]

    def index
      authorize Project
      render json: policy_scope(Project).default_first.map { |project| project_json(project) }
    end

    def show
      render json: project_json(@project)
    end

    def create
      project = current_user.projects.build(project_params)
      authorize project
      project.save!
      render json: project_json(project), status: :created
    end

    def destroy
      if @project.default_project?
        render json: { error: "Default project cannot be deleted." }, status: :conflict
        return
      end

      @project.destroy!
      render json: { status: "deleted" }
    end

    private

    def set_project
      @project = policy_scope(Project).find(params[:id])
      authorize @project
    end

    def project_params
      params.require(:project).permit(
        :name, :path, :image, :tailscale, :vnc_enabled, :vnc_geometry,
        :vnc_depth, :docker_enabled, :smb_enabled, :ssh_start_tmux,
        :mount_home, :home_path, :data_path, :oidc_enabled, :gcp_oidc_enabled,
        :gcp_oidc_config_id, :gcp_service_account_email, :gcp_principal_scope,
        gcp_roles: []
      ).to_h
    end

    def project_json(project)
      {
        id: project.id,
        name: project.name,
        path: project.path,
        image: project.image,
        tailscale: project.tailscale,
        vnc_enabled: project.vnc_enabled,
        vnc_geometry: project.vnc_geometry,
        vnc_depth: project.vnc_depth,
        docker_enabled: project.docker_enabled,
        smb_enabled: project.smb_enabled,
        ssh_start_tmux: project.ssh_start_tmux,
        default_project: project.default_project,
        mount_home: project.mount_home,
        home_path: project.home_path,
        data_path: project.data_path,
        oidc_enabled: project.oidc_enabled,
        gcp_oidc_enabled: project.gcp_oidc_enabled,
        gcp_oidc_config_id: project.gcp_oidc_config_id,
        gcp_oidc_config: project.gcp_oidc_config && {
          id: project.gcp_oidc_config.id,
          name: project.gcp_oidc_config.name,
          project_id: project.gcp_oidc_config.project_id,
          project_number: project.gcp_oidc_config.project_number,
          default_service_account_email: project.gcp_oidc_config.default_service_account_email
        },
        gcp_service_account_email: project.gcp_service_account_email,
        gcp_principal_scope: project.gcp_principal_scope,
        gcp_roles: project.gcp_roles_list,
        created_at: project.created_at
      }
    end
  end
end
