class User < ApplicationRecord
  has_secure_password
  encrypts :smb_password

  def smb_password
    super
  rescue ActiveRecord::Encryption::Errors::Decryption
    nil
  end
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
  validates :sandbox_archive_retention_days, numericality: { only_integer: true, greater_than_or_equal_to: 0, allow_nil: true }
  validates :terminal_emulator, inclusion: { in: %w[ghostty xterm], allow_nil: true }

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

  def chrome_persist_profile?
    chrome_persist_profile
  end

  def effective_archive_retention_days
    return sandbox_archive_retention_days if sandbox_archive_retention_days.present?

    @effective_archive_retention_days_fallback ||= Setting.instance.sandbox_archive_retention_days || 30
  end
end
