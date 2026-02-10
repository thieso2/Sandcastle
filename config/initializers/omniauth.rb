Rails.application.config.middleware.use OmniAuth::Builder do
  provider :github,
    ENV.fetch("GITHUB_CLIENT_ID", ""),
    ENV.fetch("GITHUB_CLIENT_SECRET", ""),
    scope: "user:email"

  provider :google_oauth2,
    ENV.fetch("GOOGLE_CLIENT_ID", ""),
    ENV.fetch("GOOGLE_CLIENT_SECRET", ""),
    scope: "email,profile",
    prompt: "select_account",
    name: "google"
end

OmniAuth.config.allowed_request_methods = [ :post ]
OmniAuth.config.silence_get_warning = true

OmniAuth.config.on_failure = proc { |env|
  error = env["omniauth.error"]
  if error
    Rails.logger.error "[OAuth Debug] error_class=#{error.class}"
    Rails.logger.error "[OAuth Debug] error_message=#{error.message}"
    if error.respond_to?(:response)
      resp = error.response
      Rails.logger.error "[OAuth Debug] response_status=#{resp.status}" if resp.respond_to?(:status)
      Rails.logger.error "[OAuth Debug] response_body=#{resp.body}" if resp.respond_to?(:body)
    end
    if error.respond_to?(:code)
      Rails.logger.error "[OAuth Debug] error_code=#{error.code}"
    end
  end
  OmniAuth::FailureEndpoint.new(env).redirect_to_failure
}
