module Api
  class BaseController < ActionController::API
    include ApiAuthentication

    rescue_from ActiveRecord::RecordNotFound do
      render json: { error: "Not found" }, status: :not_found
    end

    rescue_from ActiveRecord::RecordInvalid do |e|
      render json: { error: e.message }, status: :unprocessable_entity
    end

    rescue_from SandboxManager::Error do |e|
      render json: { error: e.message }, status: :unprocessable_entity
    end
  end
end
