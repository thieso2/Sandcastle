class Sandbox < ApplicationRecord
  include ActionView::RecordIdentifier  # For dom_id in Turbo broadcasts

  belongs_to :user
  has_many :routes, dependent: :destroy
  has_many :container_metrics, dependent: :delete_all

  VNC_GEOMETRIES = %w[1280x900 1366x768 1440x900 1600x900 1920x1080 2560x1440].freeze
  VNC_DEPTHS = [ 8, 16, 24, 32 ].freeze

  validates :name, presence: true,
    uniqueness: { scope: :user_id, conditions: -> { where.not(status: %w[destroyed archived]) } }
  validates :name, format: { with: /\A[a-z][a-z0-9_-]{0,62}\z/, message: "must be lowercase alphanumeric" },
    unless: -> { status.in?(%w[destroyed archived]) }
  validates :status, inclusion: { in: %w[pending running stopped destroyed archived] }
  validates :image, presence: true
  validates :vnc_geometry, inclusion: { in: VNC_GEOMETRIES }
  validates :vnc_depth, inclusion: { in: VNC_DEPTHS }
  validate :smb_prerequisites, if: -> { smb_enabled? }

  scope :active, -> { where.not(status: %w[destroyed archived]) }
  scope :archived, -> { where(status: "archived") }
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

  def smb_enabled?
    smb_enabled
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

  def smb_prerequisites
    errors.add(:smb_enabled, "requires Tailscale to be enabled") unless user&.tailscale_enabled?
    errors.add(:smb_enabled, "requires an SMB password to be set in Settings") unless user&.smb_password.present?
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
