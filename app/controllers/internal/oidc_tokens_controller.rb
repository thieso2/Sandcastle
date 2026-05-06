module Internal
  class OidcTokensController < ActionController::API
    before_action :require_internal_host!

    def create
      sandbox = Sandbox.authenticate_oidc_runtime_token(bearer_token)
      return render json: { error: "Unauthorized" }, status: :unauthorized unless sandbox
      return render json: { error: "OIDC is disabled for this sandbox" }, status: :forbidden unless sandbox.oidc_enabled?
      return render json: { error: "Sandbox is not running" }, status: :conflict unless sandbox.status == "running"

      audience = params[:audience].to_s.strip
      return render json: { error: "audience is required" }, status: :unprocessable_entity if audience.blank?

      token = OidcSigner.mint(user: sandbox.user, sandbox: sandbox, audience: audience)
      payload, = JWT.decode(token, nil, false)

      render json: {
        token: token,
        expires_at: Time.zone.at(payload["exp"]).iso8601,
        issuer: OidcSigner.issuer,
        subject: OidcSigner.subject_for(user: sandbox.user, sandbox: sandbox)
      }
    rescue OidcSigner::Error, ArgumentError => e
      render json: { error: e.message }, status: :unprocessable_entity
    end

    private

    def bearer_token
      authorization = request.headers["Authorization"].to_s
      authorization.delete_prefix("Bearer ").presence
    end

    def require_internal_host!
      return if internal_hosts.include?(request.host)

      render json: { error: "Not found" }, status: :not_found
    end

    def internal_hosts
      raw = ENV.fetch("SANDCASTLE_OIDC_INTERNAL_HOSTS", "sandcastle-web,localhost,127.0.0.1")
      raw.split(",").map(&:strip).reject(&:blank?)
    end
  end
end
