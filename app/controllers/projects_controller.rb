class ProjectsController < ApplicationController
  def new
    @project = Current.user.projects.build(
      image: SandboxManager::DEFAULT_IMAGE,
      tailscale: Current.user.tailscale_enabled?,
      vnc_enabled: Current.user.default_vnc_enabled,
      vnc_geometry: "1280x900",
      vnc_depth: 24,
      docker_enabled: Current.user.default_docker_enabled,
      smb_enabled: Current.user.default_smb_enabled && Current.user.tailscale_enabled? && Current.user.smb_password.present?,
      ssh_start_tmux: Current.user.default_ssh_start_tmux
    )
    authorize @project
  end

  def create
    @project = Current.user.projects.build(project_params)
    authorize @project

    if @project.save
      redirect_to new_sandbox_path, notice: "Project #{@project.name} created."
    else
      flash.now[:alert] = @project.errors.full_messages.join(", ")
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    @project = policy_scope(Project).find(params[:id])
    authorize @project
    @project.destroy!
    redirect_to new_sandbox_path, notice: "Project deleted."
  end

  private

  def project_params
    params.require(:project).permit(
      :name, :path, :image, :tailscale, :vnc_enabled, :vnc_geometry,
      :vnc_depth, :docker_enabled, :smb_enabled, :ssh_start_tmux
    )
  end
end
