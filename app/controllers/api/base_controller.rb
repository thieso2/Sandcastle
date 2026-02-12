module Api
  class BaseController < ActionController::API
    include ApiAuthentication
    include Pundit::Authorization

    rescue_from ActiveRecord::RecordNotFound do
      render json: { error: "Not found" }, status: :not_found
    end

    rescue_from ActiveRecord::RecordInvalid do |e|
      render json: { error: e.message }, status: :unprocessable_entity
    end

    rescue_from SandboxManager::Error do |e|
      render json: { error: e.message }, status: :unprocessable_entity
    end

    rescue_from TailscaleManager::Error do |e|
      render json: { error: e.message }, status: :unprocessable_entity
    end

    rescue_from RouteManager::Error do |e|
      render json: { error: e.message }, status: :unprocessable_entity
    end

    rescue_from Pundit::NotAuthorizedError do
      render json: { error: "Forbidden" }, status: :forbidden
    end

    private

    def pundit_user = current_user
  end
end
