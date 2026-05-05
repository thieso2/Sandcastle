module Api
  class ProjectsController < BaseController
    before_action :set_project, only: %i[show destroy]

    def index
      authorize Project
      render json: policy_scope(Project).order(:name).map { |project| project_json(project) }
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
        :vnc_depth, :docker_enabled, :smb_enabled, :ssh_start_tmux
      )
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
        created_at: project.created_at
      }
    end
  end
end
