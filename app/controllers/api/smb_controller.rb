module Api
  class SmbController < BaseController
    def set_password
      if current_user.update(smb_password: params.require(:password))
        SandboxManager.new.update_smb_password(user: current_user)
        render json: { status: "ok" }
      else
        render json: { error: current_user.errors.full_messages.join(", ") }, status: :unprocessable_entity
      end
    end
  end
end
