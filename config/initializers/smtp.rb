Rails.application.config.after_initialize do
  ActionMailer::Base.delivery_method = :smtp
end

# Interceptor to set SMTP settings per delivery from Setting model
class DynamicSmtpInterceptor
  def self.delivering_email(message)
    setting = Setting.instance
    smtp = setting.smtp_settings

    Rails.logger.info "[SMTP] Interceptor fired for message to=#{message.to.inspect} subject=#{message.subject.inspect}"
    Rails.logger.info "[SMTP] DB settings: #{smtp.reject { |k, _| k == :password }.inspect}"
    Rails.logger.info "[SMTP] smtp_configured?: #{Setting.smtp_configured?}"

    if smtp.present?
      message.delivery_method(:smtp, smtp)
      Rails.logger.info "[SMTP] Applied dynamic SMTP settings: address=#{smtp[:address]} port=#{smtp[:port]} user=#{smtp[:user_name]}"
    else
      Rails.logger.warn "[SMTP] No SMTP settings in DB, using defaults (localhost:25)"
    end

    # Set from address if not already set by the mailer
    from_address = Setting.smtp_from_address
    if from_address.present? && message.from == [ "from@example.com" ]
      message.from = from_address
      Rails.logger.info "[SMTP] Overrode from address to #{from_address}"
    end

    Rails.logger.info "[SMTP] Final delivery_method=#{message.delivery_method.class} from=#{message.from.inspect} to=#{message.to.inspect}"
  end
end

Rails.application.config.after_initialize do
  ActionMailer::Base.register_interceptor(DynamicSmtpInterceptor)
end
