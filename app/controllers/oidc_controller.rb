class OidcController < ApplicationController
  allow_unauthenticated_access

  def discovery
    fresh_when(strong_etag: OidcSigner.kid, public: true)
    expires_in 1.hour, public: true
    render json: OidcSigner.discovery_document
  end

  def jwks
    fresh_when(strong_etag: OidcSigner.kid, public: true)
    expires_in 1.hour, public: true
    render json: OidcSigner.jwks
  end
end
