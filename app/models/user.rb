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
  has_many :injected_files, dependent: :destroy
  has_many :persisted_paths, dependent: :destroy
  has_many :ignored_paths, dependent: :destroy

  DEFAULT_PERSISTED_PATHS = %w[.claude .codex].freeze

  after_create_commit :seed_default_persisted_paths

  normalizes :email_address, with: ->(e) { e.strip.downcase }
  normalizes :name, with: ->(n) { n.strip.downcase }

  validates :name, presence: true, uniqueness: true,
    format: { with: /\A[a-z][a-z0-9_-]{1,30}\z/, message: "must be lowercase alphanumeric (2-31 chars, start with letter)" }
  validates :email_address, presence: true, uniqueness: true
  validates :status, inclusion: { in: %w[active suspended pending_approval] }
  validates :sandbox_archive_retention_days, numericality: { only_integer: true, greater_than_or_equal_to: 0, allow_nil: true }
  validates :terminal_emulator, inclusion: { in: %w[ghostty xterm], allow_nil: true }
  validate :validate_custom_links
  validate :validate_ssh_keys

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

  def effective_archive_retention_days
    return sandbox_archive_retention_days if sandbox_archive_retention_days.present?

    @effective_archive_retention_days_fallback ||= Setting.instance.sandbox_archive_retention_days || 30
  end

  def all_ssh_keys_text
    keys = ssh_keys.presence&.filter_map { |k| k["key"].presence }
    if keys.present?
      keys.join("\n")
    else
      ssh_public_key
    end
  end

  CUSTOM_LINK_SHOW_ON_VALUES = %w[all desktop tablet phone].freeze
  CUSTOM_LINK_TEMPLATE_VARS = %w[user hostname ssh_port sandbox tailscale_ip tmux_cmd tmux_cmd_encoded].freeze
  TMUX_CMD = "tmux new-session -A -s main".freeze

  def expand_custom_link_url(url_template, sandbox:, tailscale_ip: nil)
    hostname = ENV.fetch("SANDCASTLE_HOST", "localhost")
    url_template.gsub(/\{(\w+)\}/) do |match|
      case $1
      when "user" then name
      when "hostname" then hostname
      when "ssh_port" then sandbox.ssh_port.to_s
      when "sandbox" then sandbox.name
      when "tailscale_ip" then tailscale_ip.to_s
      when "tmux_cmd" then TMUX_CMD
      when "tmux_cmd_encoded" then ERB::Util.url_encode(TMUX_CMD)
      else match
      end
    end
  end

  private

  def seed_default_persisted_paths
    DEFAULT_PERSISTED_PATHS.each do |p|
      persisted_paths.create(path: p)
    end
  end

  def validate_ssh_keys
    return if ssh_keys.blank?
    unless ssh_keys.is_a?(Array)
      errors.add(:ssh_keys, "must be an array")
      return
    end
    ssh_keys.each_with_index do |entry, i|
      unless entry.is_a?(Hash) && entry["key"].present?
        errors.add(:ssh_keys, "entry #{i + 1} must have a key")
        next
      end
      unless entry["key"].match?(/\A(ssh-|ecdsa-|sk-)\S+ \S+/)
        errors.add(:ssh_keys, "entry #{i + 1} does not look like a valid SSH public key")
      end
    end
  end

  def validate_custom_links
    return if custom_links.blank?
    unless custom_links.is_a?(Array)
      errors.add(:custom_links, "must be an array")
      return
    end
    custom_links.each_with_index do |link, i|
      unless link.is_a?(Hash) && link["name"].present? && link["url"].present?
        errors.add(:custom_links, "entry #{i + 1} must have a name and url")
      end
      if link["show_on"].present? && !CUSTOM_LINK_SHOW_ON_VALUES.include?(link["show_on"])
        errors.add(:custom_links, "entry #{i + 1} show_on must be one of: #{CUSTOM_LINK_SHOW_ON_VALUES.join(', ')}")
      end
    end
  end
end
