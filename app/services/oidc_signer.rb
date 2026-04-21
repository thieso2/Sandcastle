require "jwt"

# Signs OIDC ID tokens that external clouds (GCP first, AWS/Azure later)
# verify against Sandcastle's JWKS endpoint. See
# /Users/sebastian/.claude/plans/temporal-tinkering-plum.md for the slice's
# scope and the GCP-side setup.
class OidcSigner
  class Error < StandardError; end
  class MissingKey < Error; end

  ALGORITHM = "RS256".freeze
  DEFAULT_TTL = 15.minutes
  # GCP caps google.subject at 127 characters. Keep our sub well under.
  SUBJECT_MAX = 127

  class << self
    def private_key
      @private_key ||= load_private_key
    end

    def public_key
      private_key.public_key
    end

    # Key id: first 8 hex chars of SHA256 over the SubjectPublicKeyInfo DER.
    # Stable across restarts for a given key, changes on rotation.
    def kid
      @kid ||= Digest::SHA256.hexdigest(public_key.to_der)[0, 8]
    end

    def issuer
      host = ENV.fetch("SANDCASTLE_HOST") { raise Error, "SANDCASTLE_HOST is not set" }
      "https://#{host}"
    end

    def discovery_document
      {
        issuer: issuer,
        jwks_uri: "#{issuer}/oauth/jwks",
        id_token_signing_alg_values_supported: [ ALGORITHM ],
        response_types_supported: [ "id_token" ],
        subject_types_supported: [ "public" ],
        scopes_supported: [ "openid" ],
        claims_supported: %w[iss sub aud iat exp nbf jti user sandbox sandbox_id email image]
      }
    end

    def jwks
      jwk = JWT::JWK.new(public_key, { kid: kid, use: "sig", alg: ALGORITHM })
      { keys: [ jwk.export ] }
    end

    def mint(user:, sandbox:, audience:, ttl: DEFAULT_TTL)
      raise ArgumentError, "audience is required" if audience.to_s.empty?
      raise ArgumentError, "user.sandbox mismatch" if sandbox.user_id != user.id

      # Backdate iat/nbf by 30s to absorb minor clock skew between Sandcastle
      # and GCP STS — otherwise tokens minted in the same second as the
      # request get rejected as "issued in the future."
      now = Time.current.to_i - 30
      subject = build_subject(user, sandbox)
      if subject.length > SUBJECT_MAX
        raise Error, "sub exceeds #{SUBJECT_MAX} chars: #{subject}"
      end

      payload = {
        iss: issuer,
        sub: subject,
        aud: audience,
        iat: now,
        nbf: now,
        exp: Time.current.to_i + ttl.to_i,
        jti: SecureRandom.uuid_v7,
        user: user.name,
        sandbox: sandbox.name,
        sandbox_id: sandbox.id,
        email: user.email_address,
        image: sandbox.image
      }

      JWT.encode(payload, private_key, ALGORITHM, { kid: kid, typ: "JWT" })
    end

    # Mostly for tests/debugging. Verifies signature and returns [payload, header].
    def decode(token)
      jwk = JWT::JWK.new(public_key, { kid: kid })
      jwks_loader = ->(_opts) { { keys: [ jwk.export ] } }
      JWT.decode(token, nil, true,
        algorithms: [ ALGORITHM ],
        jwks: jwks_loader,
        verify_iss: true, iss: issuer,
        verify_iat: true
      )
    end

    # Reset memoization — used by tests to swap in a throwaway key.
    def reset!
      @private_key = nil
      @kid = nil
    end

    private

    def build_subject(user, sandbox)
      "sandcastle:user:#{user.name}:sandbox:#{sandbox.name}"
    end

    def load_private_key
      raw = ENV["OIDC_PRIVATE_KEY_PEM"]
      raise MissingKey, "OIDC_PRIVATE_KEY_PEM is not set" if raw.to_s.strip.empty?

      # Accept either a raw PEM or a base64-encoded PEM. Base64 is the safer
      # transport for docker/foreman/systemd, which all mishandle multi-line
      # env vars in one way or another. We detect by peeking at the first
      # non-whitespace bytes — a real PEM starts with "-----".
      pem = if raw.lstrip.start_with?("-----")
        raw
      else
        begin
          Base64.decode64(raw)
        rescue ArgumentError
          raw
        end
      end

      OpenSSL::PKey::RSA.new(pem)
    rescue OpenSSL::PKey::RSAError, OpenSSL::PKey::PKeyError => e
      raise MissingKey, "OIDC_PRIVATE_KEY_PEM is not a valid RSA key: #{e.message}"
    end
  end
end
