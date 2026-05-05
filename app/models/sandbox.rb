class Sandbox < ApplicationRecord
  include ActionView::RecordIdentifier  # For dom_id in Turbo broadcasts

  belongs_to :user
  belongs_to :gcp_oidc_config, optional: true
  has_many :routes, dependent: :destroy
  has_many :container_metrics, dependent: :delete_all
  has_many :sandbox_mounts, dependent: :destroy

  OIDC_TOKEN_PREFIX = "sc_oidc".freeze
  VNC_GEOMETRIES = %w[1280x900 1366x768 1440x900 1600x900 1920x1080 2560x1440].freeze
  VNC_DEPTHS = [ 8, 16, 24, 32 ].freeze
  GCP_PRINCIPAL_SCOPES = %w[sandbox user].freeze
  GCP_SERVICE_ACCOUNT_EMAIL_FORMAT = /\A[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.iam\.gserviceaccount\.com\z/

  before_validation :normalize_gcp_identity

  validates :name, presence: true,
    uniqueness: { scope: [ :user_id, :project_name ], conditions: -> { where.not(status: %w[destroyed archived]) } }
  validates :name, format: { with: /\A[a-z][a-z0-9_-]{0,62}\z/, message: "must be lowercase alphanumeric" },
    unless: -> { status.in?(%w[destroyed archived]) }
  validates :status, inclusion: { in: %w[pending running stopped destroyed archived] }
  validates :image, presence: true
  validates :vnc_geometry, inclusion: { in: VNC_GEOMETRIES }
  validates :vnc_depth, inclusion: { in: VNC_DEPTHS }
  validates :gcp_principal_scope, inclusion: { in: GCP_PRINCIPAL_SCOPES }
  validates :gcp_service_account_email, format: { with: GCP_SERVICE_ACCOUNT_EMAIL_FORMAT, allow_blank: true }
  validate :smb_prerequisites, if: -> { smb_enabled? }
  validate :validate_gcp_roles
  validate :validate_gcp_oidc_config_owner
  validate :validate_data_path
  validate :validate_home_path
  validate :validate_home_mount_options
  validate :validate_project_name

  before_validation :normalize_mount_paths
  before_validation :normalize_project_name

  scope :active, -> { where.not(status: %w[destroyed archived]) }
  scope :archived, -> { where(status: "archived") }
  scope :running, -> { where(status: "running") }

  # Turbo Streams for real-time UI updates
  after_create_commit :broadcast_prepend_to_dashboard
  after_update_commit :broadcast_replace_to_dashboard
  after_destroy_commit :broadcast_remove_from_dashboard

  def full_name
    "#{user.name}-#{hostname}"
  end

  def hostname
    return name if project_name.blank?
    "#{name}-#{project_name}"
  end

  def display_name
    return name if project_name.blank?
    "#{project_name}:#{name}"
  end

  def connect_command
    "sandcastle connect #{name}"
  end

  def routed?
    routes.loaded? ? routes.any? : routes.exists?
  end

  def temp?
    temporary?
  end

  def smb_enabled?
    smb_enabled
  end

  def oidc_enabled?
    oidc_enabled
  end

  def gcp_oidc_enabled?
    gcp_oidc_enabled
  end

  def gcp_roles_list
    Array(gcp_roles).flat_map { |role| role.to_s.split(/[\n,]/) }
      .map(&:strip)
      .reject(&:blank?)
      .uniq
  end

  def gcp_oidc_configured?
    oidc_enabled? &&
      gcp_oidc_enabled? &&
      gcp_oidc_config.present? &&
      effective_gcp_service_account_email.present? &&
      gcp_oidc_config.configured?
  end

  def effective_gcp_service_account_email
    gcp_service_account_email.presence || gcp_oidc_config&.default_service_account_email
  end

  def rotate_oidc_secret!
    raw_secret = SecureRandom.hex(32)
    update!(
      oidc_secret_digest: BCrypt::Password.create(raw_secret),
      oidc_secret_rotated_at: Time.current
    )
    "#{OIDC_TOKEN_PREFIX}_#{id}_#{raw_secret}"
  end

  def clear_oidc_secret!
    update!(oidc_secret_digest: nil, oidc_secret_rotated_at: nil)
  end

  def oidc_secret_matches?(raw_secret)
    return false if oidc_secret_digest.blank? || raw_secret.blank?

    BCrypt::Password.new(oidc_secret_digest).is_password?(raw_secret)
  rescue BCrypt::Errors::InvalidHash
    false
  end

  def self.authenticate_oidc_runtime_token(raw_token)
    parts = raw_token.to_s.split("_", 4)
    return nil unless parts.length == 4
    return nil unless parts[0] == "sc" && parts[1] == "oidc"

    sandbox = find_by(id: parts[2])
    return nil unless sandbox&.oidc_enabled?
    return nil unless sandbox.oidc_secret_matches?(parts[3])

    sandbox
  end

  def home_persisted?
    mount_home? || home_path.present?
  end

  def project_path
    return unless home_path.present? && data_path.present?
    home_path == data_path ? home_path : nil
  end

  # Whether SSH logins should auto-attach to a tmux session. Per-sandbox
  # override (nullable) wins; otherwise falls back to the user's default.
  def effective_ssh_start_tmux?
    return ssh_start_tmux unless ssh_start_tmux.nil?
    user.default_ssh_start_tmux?
  end

  # Job lifecycle management
  # A job is only considered "in progress" while still within this window.
  # Past this, the claim is treated as stale — the worker almost certainly
  # crashed or was killed (SIGKILL, OOM, container restart, deploy) before
  # it could call finish_job / fail_job, so we let the next click go
  # through instead of blocking the sandbox forever.
  JOB_STALE_AFTER = 5.minutes

  def job_in_progress?
    return false if job_status.blank?
    return true if job_started_at.nil?
    job_started_at > JOB_STALE_AFTER.ago
  end

  def job_failed?
    job_error.present?
  end

  def start_job(status)
    update!(job_status: status, job_started_at: Time.current, job_error: nil)
  end

  def finish_job
    update!(job_status: nil, job_started_at: nil)
  end

  def fail_job(error_message)
    # Bypass validations — this runs inside a job's rescue, and if the
    # underlying failure was itself a validation error, update! would
    # re-raise and leave job_status stuck forever. update_columns also
    # skips callbacks, which is the right behavior here (no broadcast
    # for "we failed to record a failure").
    update_columns(
      job_status: nil,
      job_error: error_message,
      job_started_at: nil,
      updated_at: Time.current
    )
    broadcast_replace_to_dashboard
  end

  private

  def normalize_gcp_identity
    self.gcp_principal_scope = gcp_principal_scope.presence || "user"
    self.gcp_service_account_email = gcp_service_account_email.to_s.strip.presence
    self.gcp_roles = gcp_roles_list
  end

  def normalize_mount_paths
    self.data_path = normalize_mount_path(data_path, allow_root: true)
    self.home_path = normalize_mount_path(home_path, allow_root: false)
  end

  def normalize_project_name
    self.project_name = project_name.to_s.strip.presence
  end

  def normalize_mount_path(value, allow_root:)
    path = value.to_s.strip.chomp("/")
    return nil if path.blank?
    return "." if allow_root && path == "."
    path
  end

  def validate_data_path
    validate_mount_path(:data_path, allow_root: true)
  end

  def validate_home_path
    validate_mount_path(:home_path, allow_root: false)
  end

  def validate_mount_path(attribute, allow_root:)
    value = public_send(attribute)
    return if value.blank?
    return if allow_root && value == "."

    if value.start_with?("/")
      errors.add(attribute, "must be relative")
      return
    end

    if value.split("/").any? { |seg| seg.blank? || seg == "." || seg == ".." }
      errors.add(attribute, "must not contain .., ., or empty segments")
    end
  end

  def validate_home_mount_options
    return unless mount_home? && home_path.present?
    errors.add(:home_path, "cannot be combined with full home mount")
  end

  def validate_project_name
    return if project_name.blank?
    unless project_name.match?(/\A[a-z][a-z0-9_-]{0,62}\z/)
      errors.add(:project_name, "must be lowercase alphanumeric")
    end
  end

  def smb_prerequisites
    errors.add(:smb_enabled, "requires Tailscale to be enabled") unless user&.tailscale_enabled?
    errors.add(:smb_enabled, "requires an SMB password to be set in Settings") unless user&.smb_password.present?
  end

  def validate_gcp_roles
    gcp_roles_list.each do |role|
      next if role.match?(/\Aroles\/[A-Za-z0-9_.]+\z/)
      next if role.match?(/\Aprojects\/[A-Za-z0-9_-]+\/roles\/[A-Za-z0-9_.]+\z/)
      next if role.match?(/\Aorganizations\/\d+\/roles\/[A-Za-z0-9_.]+\z/)

      errors.add(:gcp_roles, "#{role} must be a predefined or custom IAM role name")
    end
  end

  def validate_gcp_oidc_config_owner
    return if gcp_oidc_config.blank? || user.blank?

    errors.add(:gcp_oidc_config, "must belong to the sandbox owner") if gcp_oidc_config.user_id != user_id
  end

  def broadcast_prepend_to_dashboard
    broadcast_prepend_to(
      [ user, "dashboard" ],
      partial: "dashboard/sandbox",
      locals: { sandbox: self },
      target: "sandboxes"
    )
  rescue => e
    Rails.logger.warn("Sandbox#broadcast_prepend: #{e.message}")
  end

  def broadcast_replace_to_dashboard
    prev_status = status_previously_was

    if status == "destroyed"
      # Purge from wherever the row lives (active or archived list).
      broadcast_remove_to([ user, "dashboard" ], target: dom_id(self))
      broadcast_remove_to([ user, "dashboard" ], target: "#{dom_id(self)}-archived")
    elsif status == "archived" && prev_status != "archived"
      # Active → archived: move the row between lists live. Prepend so the
      # most recently archived sandbox appears at the top of the list —
      # matches the `archived_at: :desc` order on the dashboard.
      broadcast_remove_to([ user, "dashboard" ], target: dom_id(self))
      broadcast_prepend_to(
        [ user, "dashboard" ],
        partial: "dashboard/archived_sandbox",
        locals: { sandbox: self },
        target: "archived-sandboxes"
      )
    elsif prev_status == "archived" && !status.in?(%w[destroyed archived])
      # Archived → active (restore): move back to active list.
      broadcast_remove_to([ user, "dashboard" ], target: "#{dom_id(self)}-archived")
      broadcast_prepend_to(
        [ user, "dashboard" ],
        partial: "dashboard/sandbox",
        locals: { sandbox: self },
        target: "sandboxes"
      )
    else
      broadcast_replace_to(
        [ user, "dashboard" ],
        partial: "dashboard/sandbox",
        locals: { sandbox: self },
        target: dom_id(self)
      )
    end
  rescue => e
    Rails.logger.warn("Sandbox#broadcast_replace: #{e.message}")
  end

  def broadcast_remove_from_dashboard
    broadcast_remove_to([ user, "dashboard" ], target: dom_id(self))
    broadcast_remove_to([ user, "dashboard" ], target: "#{dom_id(self)}-archived")
  rescue => e
    Rails.logger.warn("Sandbox#broadcast_remove: #{e.message}")
  end
end
