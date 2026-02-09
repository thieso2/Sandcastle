module Api
  class TokensController < BaseController
    skip_before_action :authenticate_api_token!, only: :create
    before_action :authenticate_with_password!, only: :create

    def index
      tokens = current_user.api_tokens
      render json: tokens.map { |t| token_json(t) }
    end

    def create
      token, raw = ApiToken.generate_for(@password_user, name: params.require(:name))
      render json: token_json(token).merge(raw_token: raw), status: :created
    end

    def destroy
      token = current_user.api_tokens.find(params[:id])
      token.destroy!
      render json: { status: "deleted" }
    end

    private

    def authenticate_with_password!
      email = params.require(:email_address)
      password = params.require(:password)
      @password_user = User.authenticate_by(email_address: email, password: password)

      unless @password_user
        render json: { error: "Invalid credentials" }, status: :unauthorized
      end
    end

    def token_json(token)
      {
        id: token.id,
        name: token.name,
        prefix: token.prefix,
        masked_token: token.masked_token,
        last_used_at: token.last_used_at,
        expires_at: token.expires_at,
        created_at: token.created_at
      }
    end
  end
end
