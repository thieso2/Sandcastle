class DeviceCode < ApplicationRecord
  belongs_to :user, optional: true
  belongs_to :api_token, optional: true

  validates :code, presence: true, uniqueness: true
  validates :user_code, presence: true
  validates :status, inclusion: { in: %w[pending approved consumed expired] }
  validates :expires_at, presence: true

  scope :pending, -> { where(status: "pending") }
  scope :not_expired, -> { where("expires_at > ?", Time.current) }

  def self.generate(client_name:)
    create!(
      code: SecureRandom.urlsafe_base64(32),
      user_code: format_user_code(SecureRandom.hex(4).upcase),
      client_name: client_name,
      expires_at: 10.minutes.from_now
    )
  end

  def expired?
    expires_at < Time.current
  end

  def pending?
    status == "pending"
  end

  def approved?
    status == "approved"
  end

  def consumed?
    status == "consumed"
  end

  def approve!(user)
    update!(status: "approved", user: user)
  end

  def consume!
    transaction do
      token, raw_token = ApiToken.generate_for(user, name: "device:#{client_name || 'cli'}")
      update!(status: "consumed", api_token: token)
      raw_token
    end
  end

  def self.format_user_code(hex)
    "#{hex[0..3]}-#{hex[4..7]}"
  end
end
