module Api
  class AuthController < ActionController::API
    def device_code
      device_code = DeviceCode.generate(client_name: params[:client_name])

      render json: {
        device_code: device_code.code,
        user_code: device_code.user_code,
        verification_url: verification_url(device_code.user_code),
        expires_in: 600,
        interval: 3
      }, status: :ok
    end

    def device_token
      code = params.require(:device_code)
      device_code = DeviceCode.find_by(code: code)

      if device_code.nil? || device_code.expired? || device_code.consumed?
        return render json: { error: "expired_token" }, status: :gone
      end

      if device_code.pending?
        return render json: { error: "authorization_pending" }, status: :precondition_required
      end

      if device_code.approved?
        raw_token = device_code.consume!
        render json: { token: raw_token }, status: :ok
      end
    end

    private

    def verification_url(user_code)
      "#{request.base_url}/auth/device?code=#{user_code}"
    end
  end
end
