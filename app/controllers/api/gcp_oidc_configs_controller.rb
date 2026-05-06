module Api
  class GcpOidcConfigsController < BaseController
    before_action :set_config, only: %i[show update destroy]

    def index
      render json: current_user.gcp_oidc_configs.order(:name).map { |config| config_json(config) }
    end

    def show
      render json: config_json(@config, include_setup: true)
    end

    def create
      config = current_user.gcp_oidc_configs.create!(config_params)
      render json: config_json(config, include_setup: true), status: :created
    end

    def update
      @config.update!(config_params)
      render json: config_json(@config, include_setup: true)
    end

    def destroy
      @config.destroy!
      render json: { status: "deleted" }
    end

    private

    def set_config
      @config = current_user.gcp_oidc_configs.find(params[:id])
    end

    def config_params
      params.permit(
        :name,
        :project_id,
        :project_number,
        :workload_identity_pool_id,
        :workload_identity_provider_id,
        :workload_identity_location
      )
    end

    def config_json(config, include_setup: false)
      json = {
        id: config.id,
        name: config.name,
        project_id: config.project_id,
        project_number: config.project_number,
        default_service_account_email: config.default_service_account_email,
        default_read_only_roles: GcpOidcConfig::DEFAULT_READ_ONLY_ROLES,
        workload_identity_pool_id: config.workload_identity_pool_id,
        workload_identity_provider_id: config.workload_identity_provider_id,
        workload_identity_location: config.workload_identity_location,
        sandbox_count: config.sandboxes.active.count,
        created_at: config.created_at,
        updated_at: config.updated_at
      }
      json[:setup] = GcpOidcSetup.new(user: current_user, config: config).as_json if include_setup
      json
    end
  end
end
