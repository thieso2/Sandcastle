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
