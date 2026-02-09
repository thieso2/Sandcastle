class ApiToken < ApplicationRecord
  belongs_to :user

  PREFIX_LENGTH = 8

  validates :name, presence: true
  validates :token_digest, presence: true
  validates :prefix, presence: true, uniqueness: true

  scope :active, -> { where("expires_at IS NULL OR expires_at > ?", Time.current) }

  def self.generate_for(user, name:, expires_in: nil)
    raw_secret = SecureRandom.hex(24)
    prefix = "sc_#{SecureRandom.hex(PREFIX_LENGTH / 2)}"
    raw_token = "#{prefix}_#{raw_secret}"

    token = user.api_tokens.create!(
      name: name,
      prefix: prefix,
      token_digest: BCrypt::Password.create(raw_secret),
      expires_at: expires_in ? Time.current + expires_in : nil
    )

    [ token, raw_token ]
  end

  def self.authenticate(raw_token)
    return nil unless raw_token&.start_with?("sc_")

    parts = raw_token.split("_", 3) # "sc", prefix_hex, secret
    return nil unless parts.length == 3

    prefix = "sc_#{parts[1]}"
    secret = parts[2]

    token = active.find_by(prefix: prefix)
    return nil unless token
    return nil unless BCrypt::Password.new(token.token_digest).is_password?(secret)

    token.update_column(:last_used_at, Time.current)
    token
  end

  def expired?
    expires_at.present? && expires_at < Time.current
  end

  def masked_token
    "#{prefix}_#{'*' * 12}"
  end
end
