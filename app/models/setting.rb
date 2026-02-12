class Setting < ApplicationRecord
  encrypts :github_client_secret, :google_client_secret, :smtp_password

  def self.instance
    find_or_create_by(id: 1)
  end

  # --- Class-level accessors with ENV fallback ---

  %i[github_client_id google_client_id].each do |attr|
    define_singleton_method(attr) do
      val = instance.send(attr)
      val.presence || ENV[attr.to_s.upcase]
    end
  end

  %i[github_client_secret google_client_secret].each do |attr|
    define_singleton_method(attr) do
      val = instance.send(attr)
      val.presence || ENV[attr.to_s.upcase]
    end
  end

  def self.github_configured?
    github_client_id.present? && github_client_secret.present?
  end

  def self.google_configured?
    google_client_id.present? && google_client_secret.present?
  end

  def self.smtp_configured?
    instance.smtp_address.present?
  end

  def self.smtp_from_address
    val = instance.smtp_from_address
    val.presence || ENV["SMTP_FROM_ADDRESS"] || "noreply@example.com"
  end

  # Skip blank secret values so "leave blank to keep" works
  %i[github_client_secret google_client_secret smtp_password].each do |attr|
    define_method(:"#{attr}=") do |value|
      super(value) if value.present?
    end
  end

  def smtp_settings
    return {} unless smtp_address.present?

    settings = {
      address: smtp_address,
      port: smtp_port || 587,
      user_name: smtp_username.presence,
      password: smtp_password.presence,
      authentication: smtp_authentication.presence&.to_sym,
      enable_starttls_auto: smtp_starttls
    }
    settings.compact
  end
end
