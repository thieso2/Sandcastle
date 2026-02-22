class Sandbox < ApplicationRecord
  include ActionView::RecordIdentifier  # For dom_id in Turbo broadcasts

  belongs_to :user
  has_many :routes, dependent: :destroy

  VNC_GEOMETRIES = %w[1280x900 1366x768 1440x900 1600x900 1920x1080 2560x1440].freeze
  VNC_DEPTHS = [ 8, 16, 24, 32 ].freeze

  validates :name, presence: true,
    uniqueness: { scope: :user_id, conditions: -> { where.not(status: "destroyed") } },
    format: { with: /\A[a-z][a-z0-9_-]{0,62}\z/, message: "must be lowercase alphanumeric" }
  validates :status, inclusion: { in: %w[pending running stopped destroyed] }
  validates :image, presence: true
  validates :vnc_geometry, inclusion: { in: VNC_GEOMETRIES }
  validates :vnc_depth, inclusion: { in: VNC_DEPTHS }

  scope :active, -> { where.not(status: "destroyed") }
  scope :running, -> { where(status: "running") }

  # Turbo Streams for real-time UI updates
  after_create_commit :broadcast_prepend_to_dashboard
  after_update_commit :broadcast_replace_to_dashboard
  after_destroy_commit :broadcast_remove_from_dashboard

  def full_name
    "#{user.name}-#{name}"
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

  # Job lifecycle management
  def job_in_progress?
    job_status.present?
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
    update!(job_status: nil, job_error: error_message, job_started_at: nil)
  end

  private

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
    # If sandbox is destroyed, remove it from the dashboard instead of replacing
    if status == "destroyed"
      broadcast_remove_to([ user, "dashboard" ], target: dom_id(self))
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
  rescue => e
    Rails.logger.warn("Sandbox#broadcast_remove: #{e.message}")
  end
end
