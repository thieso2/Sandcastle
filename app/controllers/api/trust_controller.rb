module Api
  class TrustController < BaseController
    def root_ca
      render json: {
        name: "Sandcastle Caddy Root CA",
        pem: CaddyCertificateAuthority.root_certificate_pem
      }
    end
  end
end
