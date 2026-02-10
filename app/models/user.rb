class User < ApplicationRecord
  has_secure_password
  has_many :sessions, dependent: :destroy
  has_many :sandboxes, dependent: :destroy
  has_many :api_tokens, dependent: :destroy

  encrypts :tailscale_auth_key

  normalizes :email_address, with: ->(e) { e.strip.downcase }
  normalizes :name, with: ->(n) { n.strip.downcase }

  validates :name, presence: true, uniqueness: true,
    format: { with: /\A[a-z][a-z0-9_-]{1,30}\z/, message: "must be lowercase alphanumeric (2-31 chars, start with letter)" }
  validates :email_address, presence: true, uniqueness: true
  validates :status, inclusion: { in: %w[active suspended] }

  scope :active, -> { where(status: "active") }

  def admin?
    admin
  end

  def active?
    status == "active"
  end

  def tailscale_configured?
    tailscale_auth_key.present?
  end
end
