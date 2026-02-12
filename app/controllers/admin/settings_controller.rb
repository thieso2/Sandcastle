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
        if params[:test_email].present?
          send_test_email
        else
          redirect_to edit_admin_settings_path, notice: "Settings saved."
        end
      else
        render :edit, status: :unprocessable_entity
      end
    end

    private

    def send_test_email
      if Setting.smtp_configured?
        begin
          TestMailer.test(Current.user).deliver_now
          redirect_to edit_admin_settings_path, notice: "Settings saved. Test email sent to #{Current.user.email_address}."
        rescue => e
          redirect_to edit_admin_settings_path, alert: "Settings saved, but failed to send test email: #{e.message}"
        end
      else
        redirect_to edit_admin_settings_path, alert: "Settings saved, but SMTP is not configured. Fill in at least the SMTP address."
      end
    end

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
