class GcpOidcConfig < ApplicationRecord
  belongs_to :user
  has_many :sandboxes, dependent: :nullify

  ID_FORMAT = /\A[a-z][a-z0-9-]{2,62}\z/
  SERVICE_ACCOUNT_EMAIL_FORMAT = /\A[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.iam\.gserviceaccount\.com\z/
  SUPPORTED_LOCATIONS = %w[global].freeze
  DEFAULT_SERVICE_ACCOUNT_ID = "sandcastle-reader".freeze
  DEFAULT_READ_ONLY_ROLES = %w[
    roles/viewer
    roles/storage.objectViewer
    roles/bigquery.dataViewer
    roles/bigquery.jobUser
    roles/logging.viewer
    roles/monitoring.viewer
  ].freeze

  before_validation :normalize_fields

  validates :name, presence: true, uniqueness: { scope: :user_id }
  validates :project_number, presence: true, format: { with: /\A\d+\z/ }
  validates :project_id, format: { with: /\A[a-z][a-z0-9-]{4,61}[a-z0-9]\z/, allow_blank: true }
  validates :workload_identity_pool_id, presence: true, format: { with: ID_FORMAT }
  validates :workload_identity_provider_id, presence: true, format: { with: ID_FORMAT }
  validates :workload_identity_location, presence: true,
    inclusion: { in: SUPPORTED_LOCATIONS, message: "must be global for GCP Workload Identity Federation" }
  validates :default_service_account_email, format: { with: SERVICE_ACCOUNT_EMAIL_FORMAT, allow_blank: true }

  def self.default_service_account_email_for(project_id)
    return nil if project_id.blank?

    "#{DEFAULT_SERVICE_ACCOUNT_ID}@#{project_id}.iam.gserviceaccount.com"
  end

  def configured?
    project_number.present? &&
      workload_identity_pool_id.present? &&
      workload_identity_provider_id.present?
  end

  def project_selector
    project_id.presence || project_number
  end

  def default_service_account_id
    default_service_account_email.to_s.split("@", 2).first.presence || DEFAULT_SERVICE_ACCOUNT_ID
  end

  private

  def normalize_fields
    self.name = name.to_s.strip
    self.project_id = project_id.to_s.strip.presence
    self.project_number = project_number.to_s.strip
    self.workload_identity_pool_id = workload_identity_pool_id.to_s.strip
    self.workload_identity_provider_id = workload_identity_provider_id.to_s.strip
    self.workload_identity_location = workload_identity_location.to_s.strip.presence || "global"
    self.default_service_account_email = default_service_account_email.to_s.strip.presence ||
      self.class.default_service_account_email_for(project_id)
  end
end
