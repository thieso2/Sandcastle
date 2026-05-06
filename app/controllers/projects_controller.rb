class ProjectsController < ApplicationController
  before_action :set_project, only: [ :edit, :update, :destroy ]

  def new
    defaults = Current.user.default_project
    @project = Current.user.projects.build(
      image: defaults.image,
      tailscale: Current.user.tailscale_enabled? || defaults.tailscale,
      vnc_enabled: defaults.vnc_enabled,
      vnc_geometry: defaults.vnc_geometry,
      vnc_depth: defaults.vnc_depth,
      docker_enabled: defaults.docker_enabled,
      smb_enabled: defaults.smb_enabled,
      ssh_start_tmux: defaults.ssh_start_tmux
    )
    prepare_project_context
    authorize @project
  end

  def create
    @project = Current.user.projects.build(project_params)
    authorize @project

    if @project.save
      redirect_to project_return_path, notice: "Project #{@project.name} created."
    else
      prepare_project_context
      flash.now[:alert] = @project.errors.full_messages.join(", ")
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    prepare_project_context
  end

  def update
    if @project.update(project_params)
      redirect_to settings_path(anchor: "projects"), notice: "Project #{@project.name} updated."
    else
      prepare_project_context
      flash.now[:alert] = @project.errors.full_messages.join(", ")
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    if @project.default_project?
      redirect_to settings_path(anchor: "projects"), alert: "Default project cannot be deleted."
      return
    end

    @project.destroy!
    redirect_to settings_path(anchor: "projects"), notice: "Project deleted."
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
      :gcp_roles_text
    ).to_h.tap { |attrs| attrs[:gcp_roles] = parse_gcp_roles(attrs.delete("gcp_roles_text")) if attrs.key?("gcp_roles_text") }
  end

  def project_return_path
    return_to = params[:return_to].to_s
    return return_to if return_to.start_with?("/") && !return_to.start_with?("//")

    settings_path(anchor: "projects")
  end

  def prepare_project_context
    @gcp_oidc_configs = Current.user.gcp_oidc_configs.order(:name)
  end

  def parse_gcp_roles(value)
    Array(value).flat_map { |role| role.to_s.split(/[\n,]/) }
      .map(&:strip)
      .reject(&:blank?)
      .uniq
  end
end
