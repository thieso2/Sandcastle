class Project < ApplicationRecord
  belongs_to :user
  belongs_to :gcp_oidc_config, optional: true

  GCP_PRINCIPAL_SCOPES = Sandbox::GCP_PRINCIPAL_SCOPES
  GCP_SERVICE_ACCOUNT_EMAIL_FORMAT = Sandbox::GCP_SERVICE_ACCOUNT_EMAIL_FORMAT

  validates :name, presence: true, uniqueness: { scope: :user_id }
  validates :name, format: { with: /\A[a-z][a-z0-9_-]{0,62}\z/, message: "must be lowercase alphanumeric" }
  validates :path, presence: true, unless: :default_project?
  validates :image, presence: true
  validates :vnc_geometry, inclusion: { in: Sandbox::VNC_GEOMETRIES }
  validates :vnc_depth, inclusion: { in: Sandbox::VNC_DEPTHS }
  validates :gcp_principal_scope, inclusion: { in: GCP_PRINCIPAL_SCOPES }
  validates :gcp_service_account_email, format: { with: GCP_SERVICE_ACCOUNT_EMAIL_FORMAT, allow_blank: true }
  validate :validate_path
  validate :validate_home_path
  validate :validate_data_path
  validate :validate_gcp_roles
  validate :validate_gcp_oidc_config_owner
  validate :smb_prerequisites, if: -> { smb_enabled? }

  before_validation :normalize_path
  before_validation :normalize_defaults

  scope :default_first, -> { order(default_project: :desc, name: :asc) }

  def self.create_default_for!(user)
    project = user.projects.find_or_initialize_by(name: "default")
    project.assign_attributes(default_project_attributes_for(user))
    project.save!
    project
  end

  def self.default_project_attributes_for(user)
    {
      path: nil,
      image: SandboxManager::DEFAULT_IMAGE,
      tailscale: false,
      vnc_enabled: user.default_vnc_enabled.nil? ? true : user.default_vnc_enabled,
      vnc_geometry: "1280x900",
      vnc_depth: 24,
      docker_enabled: user.default_docker_enabled.nil? ? true : user.default_docker_enabled,
      smb_enabled: user.default_smb_enabled && user.tailscale_enabled? && user.smb_password.present?,
      ssh_start_tmux: user.default_ssh_start_tmux.nil? ? true : user.default_ssh_start_tmux,
      default_project: true,
      mount_home: user.default_mount_home,
      data_path: user.default_data_path,
      oidc_enabled: user.default_oidc_enabled
    }
  end

  def apply_to_sandbox(sandbox)
    sandbox.project_name = default_project? ? nil : name
    sandbox.mount_home = default_project? ? mount_home : false
    sandbox.home_path = default_project? ? home_path : path
    sandbox.data_path = default_project? ? data_path : path
    sandbox.image = image
    sandbox.tailscale = tailscale
    sandbox.vnc_enabled = vnc_enabled
    sandbox.vnc_geometry = vnc_geometry
    sandbox.vnc_depth = vnc_depth
    sandbox.docker_enabled = docker_enabled
    sandbox.smb_enabled = smb_enabled
    sandbox.ssh_start_tmux = ssh_start_tmux
    sandbox.oidc_enabled = oidc_enabled || gcp_oidc_enabled
    sandbox.gcp_oidc_enabled = gcp_oidc_enabled
    sandbox.gcp_oidc_config = gcp_oidc_config
    sandbox.gcp_service_account_email = gcp_service_account_email
    sandbox.gcp_principal_scope = gcp_principal_scope
    sandbox.gcp_roles = gcp_roles_list
    sandbox
  end

  def gcp_roles_list
    Array(gcp_roles).flat_map { |role| role.to_s.split(/[\n,]/) }
      .map(&:strip)
      .reject(&:blank?)
      .uniq
  end

  private

  def normalize_path
    self.path = clean_path(path, allow_root: false)
  end

  def normalize_defaults
    self.home_path = clean_path(home_path, allow_root: false)
    self.data_path = clean_path(data_path, allow_root: true)
    self.gcp_principal_scope = gcp_principal_scope.presence || "user"
    self.gcp_service_account_email = gcp_service_account_email.to_s.strip.presence
    self.gcp_roles = gcp_roles_list
  end

  def clean_path(value, allow_root:)
    path = value.to_s.strip.chomp("/")
    return nil if path.blank?
    return "." if allow_root && path == "."
    path
  end

  def validate_path
    validate_mount_path(:path, allow_root: false)
  end

  def validate_home_path
    validate_mount_path(:home_path, allow_root: false)
    errors.add(:home_path, "cannot be combined with full home mount") if mount_home? && home_path.present?
  end

  def validate_data_path
    validate_mount_path(:data_path, allow_root: true)
  end

  def validate_mount_path(attribute, allow_root:)
    value = public_send(attribute)
    return if value.blank?
    return if allow_root && value == "."

    errors.add(attribute, "must be relative") and return if value.start_with?("/")
    errors.add(attribute, "must be a subdir without .., ., or empty segments") if value == "." || value.split("/").any? { |seg| seg.blank? || seg == "." || seg == ".." }
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

    errors.add(:gcp_oidc_config, "must belong to the project owner") if gcp_oidc_config.user_id != user_id
  end
end
