module ApiAuthentication
  extend ActiveSupport::Concern

  included do
    before_action :authenticate_api_token!
    attr_reader :current_api_token
  end

  private

  def authenticate_api_token!
    raw_token = request.headers["Authorization"]&.delete_prefix("Bearer ")
    @current_api_token = ApiToken.authenticate(raw_token)

    unless @current_api_token
      render json: { error: "Unauthorized" }, status: :unauthorized
    end
  end

  def current_user
    @current_api_token&.user
  end

  def require_admin!
    unless current_user&.admin?
      render json: { error: "Forbidden" }, status: :forbidden
    end
  end
end
