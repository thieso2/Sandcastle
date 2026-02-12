module Admin
  class SettingsController < BaseController
    def edit
      @setting = Setting.instance
      authorize @setting
    end

    def update
      @setting = Setting.instance
      authorize @setting

      if @setting.update(setting_params)
        redirect_to edit_admin_settings_path, notice: "Settings saved."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def test_email
      @setting = Setting.instance
      authorize @setting, :update?

      # Save any pending changes first
      @setting.update(setting_params) if params[:setting].present?

      if Setting.smtp_configured?
        begin
          TestMailer.test(Current.user).deliver_now
          redirect_to edit_admin_settings_path, notice: "Test email sent to #{Current.user.email_address}."
        rescue => e
          redirect_to edit_admin_settings_path, alert: "Failed to send test email: #{e.message}"
        end
      else
        redirect_to edit_admin_settings_path, alert: "SMTP is not configured. Please fill in at least the SMTP address."
      end
    end

    private

    def setting_params
      params.expect(setting: [
        :github_client_id, :github_client_secret,
        :google_client_id, :google_client_secret,
        :smtp_address, :smtp_port, :smtp_username, :smtp_password,
        :smtp_authentication, :smtp_starttls, :smtp_from_address
      ])
    end
  end
end
