Rails.application.config.after_initialize do
  ActionMailer::Base.delivery_method = :smtp

  # Use a custom delivery method class that reads settings dynamically
  ActionMailer::Base.class_eval do
    class_attribute :dynamic_smtp_settings, default: true
  end
end

# Interceptor to set SMTP settings per delivery from Setting model
class DynamicSmtpInterceptor
  def self.delivering_email(message)
    setting = Setting.instance
    smtp = setting.smtp_settings

    if smtp.present?
      message.delivery_method(:smtp, smtp)
    end

    # Set from address if not already set by the mailer
    from_address = Setting.smtp_from_address
    if from_address.present? && message.from == [ "from@example.com" ]
      message.from = from_address
    end
  end
end

Rails.application.config.after_initialize do
  ActionMailer::Base.register_interceptor(DynamicSmtpInterceptor)
end
