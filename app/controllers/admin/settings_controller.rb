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
      logger.info "[SMTP-TEST] Starting test email flow"
      logger.info "[SMTP-TEST] Setting.smtp_configured? = #{Setting.smtp_configured?}"
      logger.info "[SMTP-TEST] DB smtp_address = #{Setting.instance.smtp_address.inspect}"
      logger.info "[SMTP-TEST] DB smtp_port = #{Setting.instance.smtp_port.inspect}"
      logger.info "[SMTP-TEST] DB smtp_username = #{Setting.instance.smtp_username.inspect}"
      logger.info "[SMTP-TEST] DB smtp_password present? = #{Setting.instance.smtp_password.present?}"
      logger.info "[SMTP-TEST] DB smtp_from_address = #{Setting.instance.smtp_from_address.inspect}"
      logger.info "[SMTP-TEST] Recipient = #{Current.user.email_address}"

      if Setting.smtp_configured?
        begin
          logger.info "[SMTP-TEST] Building mail..."
          mail = TestMailer.test(Current.user)
          logger.info "[SMTP-TEST] Mail built: from=#{mail.from.inspect} to=#{mail.to.inspect} delivery_method=#{mail.delivery_method.class}"
          logger.info "[SMTP-TEST] Calling deliver_now..."
          result = mail.deliver_now
          logger.info "[SMTP-TEST] deliver_now returned: #{result.class} message_id=#{result.message_id rescue 'N/A'}"
          redirect_to edit_admin_settings_path, notice: "Settings saved. Test email sent to #{Current.user.email_address}."
        rescue => e
          logger.error "[SMTP-TEST] DELIVERY FAILED: #{e.class}: #{e.message}"
          logger.error "[SMTP-TEST] Backtrace: #{e.backtrace.first(5).join("\n")}"
          redirect_to edit_admin_settings_path, alert: "Settings saved, but failed to send: #{e.class} - #{e.message}"
        end
      else
        logger.warn "[SMTP-TEST] SMTP not configured, skipping send"
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
