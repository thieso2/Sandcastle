class User < ApplicationRecord
  has_secure_password
  has_many :sessions, dependent: :destroy
  has_many :sandboxes, dependent: :destroy
  has_many :api_tokens, dependent: :destroy
  has_many :oauth_identities, dependent: :destroy

  normalizes :email_address, with: ->(e) { e.strip.downcase }
  normalizes :name, with: ->(n) { n.strip.downcase }

  validates :name, presence: true, uniqueness: true,
    format: { with: /\A[a-z][a-z0-9_-]{1,30}\z/, message: "must be lowercase alphanumeric (2-31 chars, start with letter)" }
  validates :email_address, presence: true, uniqueness: true
  validates :status, inclusion: { in: %w[active suspended pending_approval] }

  generates_token_for :invite, expires_in: 72.hours do
    password_salt&.last(10)
  end

  scope :active, -> { where(status: "active") }

  def admin?
    admin
  end

  def active?
    status == "active"
  end

  def suspended?
    status == "suspended"
  end

  def pending_approval?
    status == "pending_approval"
  end

  def tailscale_enabled?
    respond_to?(:tailscale_state) && tailscale_state == "enabled"
  end

  def tailscale_pending?
    respond_to?(:tailscale_state) && tailscale_state == "pending"
  end

  def tailscale_disabled?
    !respond_to?(:tailscale_state) || tailscale_state == "disabled"
  end

  def tailscale_auto_connect?
    tailscale_auto_connect
  end
end
