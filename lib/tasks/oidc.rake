namespace :oidc do
  desc "Generate a fresh RSA-2048 private key PEM for OIDC_PRIVATE_KEY_PEM"
  task :gen_key do
    key = OpenSSL::PKey::RSA.new(2048)
    pem = key.to_pem
    warn "# Raw PEM (copy into a file or env that handles multi-line values):"
    warn "# --- BEGIN PEM ---"
    warn pem
    warn "# --- END PEM ---"
    warn "#"
    warn "# Single-line base64 (easier to paste into .env or docker-compose):"
    warn "# OIDC_PRIVATE_KEY_PEM=<value below>"
    puts Base64.strict_encode64(pem)
  end

  desc "Mint a test OIDC JWT for a given user/sandbox/audience"
  task :mint, [ :username, :sandbox_name, :audience ] => :environment do |_t, args|
    username = args[:username] or abort "usage: rails \"oidc:mint[username,sandbox_name,audience]\""
    sandbox_name = args[:sandbox_name] or abort "sandbox_name required"
    audience = args[:audience] or abort "audience required"

    user = User.find_by!(name: username)
    sandbox = user.sandboxes.find_by!(name: sandbox_name)

    token = OidcSigner.mint(user: user, sandbox: sandbox, audience: audience)
    warn "# sub=sandcastle:user:#{user.name}:sandbox:#{sandbox.name}  aud=#{audience}"
    puts token
  end

  desc "Decode and verify an OIDC JWT against Sandcastle's current signing key"
  task :inspect, [ :token ] => :environment do |_t, args|
    token = args[:token] or abort "usage: rails \"oidc:inspect[<jwt>]\""
    payload, header = OidcSigner.decode(token)
    require "json"
    puts "header:  #{JSON.pretty_generate(header)}"
    puts "payload: #{JSON.pretty_generate(payload)}"
  end

  desc "Print the public OIDC discovery document (what /.well-known/openid-configuration returns)"
  task discovery: :environment do
    require "json"
    puts JSON.pretty_generate(OidcSigner.discovery_document)
  end

  desc "Print the public JWKS (what /oauth/jwks returns)"
  task jwks: :environment do
    require "json"
    puts JSON.pretty_generate(OidcSigner.jwks)
  end
end
