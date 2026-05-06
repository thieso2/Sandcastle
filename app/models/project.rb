class Project < ApplicationRecord
  belongs_to :user

  validates :name, presence: true, uniqueness: { scope: :user_id }
  validates :name, format: { with: /\A[a-z][a-z0-9_-]{0,62}\z/, message: "must be lowercase alphanumeric" }
  validates :path, presence: true
  validates :image, presence: true
  validates :vnc_geometry, inclusion: { in: Sandbox::VNC_GEOMETRIES }
  validates :vnc_depth, inclusion: { in: Sandbox::VNC_DEPTHS }
  validate :validate_path
  validate :smb_prerequisites, if: -> { smb_enabled? }

  before_validation :normalize_path

  def apply_to_sandbox(sandbox)
    sandbox.mount_home = false
    sandbox.home_path = path
    sandbox.data_path = path
    sandbox.image = image
    sandbox.tailscale = tailscale
    sandbox.vnc_enabled = vnc_enabled
    sandbox.vnc_geometry = vnc_geometry
    sandbox.vnc_depth = vnc_depth
    sandbox.docker_enabled = docker_enabled
    sandbox.smb_enabled = smb_enabled
    sandbox.ssh_start_tmux = ssh_start_tmux
    sandbox
  end

  private

  def normalize_path
    self.path = path.to_s.strip.chomp("/")
    self.path = nil if path.blank?
  end

  def validate_path
    return if path.blank?
    errors.add(:path, "must be relative") and return if path.start_with?("/")
    if path == "." || path.split("/").any? { |seg| seg.blank? || seg == "." || seg == ".." }
      errors.add(:path, "must be a subdir without .., ., or empty segments")
    end
  end

  def smb_prerequisites
    errors.add(:smb_enabled, "requires Tailscale to be enabled") unless user&.tailscale_enabled?
    errors.add(:smb_enabled, "requires an SMB password to be set in Settings") unless user&.smb_password.present?
  end
end
