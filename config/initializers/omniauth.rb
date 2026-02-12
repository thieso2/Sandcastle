Rails.application.config.middleware.use OmniAuth::Builder do
  provider :github,
    ENV.fetch("GITHUB_CLIENT_ID", ""),
    ENV.fetch("GITHUB_CLIENT_SECRET", ""),
    scope: "user:email",
    setup: lambda { |env|
      strategy = env["omniauth.strategy"]
      client_id = Setting.github_client_id
      client_secret = Setting.github_client_secret
      strategy.options[:client_id] = client_id if client_id.present?
      strategy.options[:client_secret] = client_secret if client_secret.present?
    }

  provider :google_oauth2,
    ENV.fetch("GOOGLE_CLIENT_ID", ""),
    ENV.fetch("GOOGLE_CLIENT_SECRET", ""),
    scope: "email,profile",
    prompt: "select_account",
    name: "google",
    setup: lambda { |env|
      strategy = env["omniauth.strategy"]
      client_id = Setting.google_client_id
      client_secret = Setting.google_client_secret
      strategy.options[:client_id] = client_id if client_id.present?
      strategy.options[:client_secret] = client_secret if client_secret.present?
    }
end

OmniAuth.config.allowed_request_methods = [ :post ]
OmniAuth.config.silence_get_warning = true
