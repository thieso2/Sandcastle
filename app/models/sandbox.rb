class Sandbox < ApplicationRecord
  include ActionView::RecordIdentifier  # For dom_id in Turbo broadcasts

  belongs_to :user
  has_many :routes, dependent: :destroy

  SSH_PORT_RANGE = (2201..2299)

  validates :name, presence: true,
    uniqueness: { scope: :user_id, conditions: -> { where.not(status: "destroyed") } },
    format: { with: /\A[a-z][a-z0-9_-]{0,62}\z/, message: "must be lowercase alphanumeric" }
  validates :ssh_port, presence: true,
    uniqueness: { conditions: -> { where.not(status: "destroyed") } },
    inclusion: { in: SSH_PORT_RANGE }
  validates :status, inclusion: { in: %w[pending running stopped destroyed] }
  validates :image, presence: true

  scope :active, -> { where.not(status: "destroyed") }
  scope :running, -> { where(status: "running") }

  before_validation :assign_ssh_port, on: :create

  # Turbo Streams for real-time UI updates
  after_create_commit :broadcast_prepend_to_dashboard
  after_update_commit :broadcast_replace_to_dashboard
  after_destroy_commit :broadcast_remove_from_dashboard

  def full_name
    "#{user.name}-#{name}"
  end

  def connect_command(host: ENV.fetch("SANDCASTLE_HOST", "localhost"))
    "ssh -p #{ssh_port} #{user.name}@#{host}"
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
      [user, "dashboard"],
      partial: "dashboard/sandbox",
      locals: { sandbox: self },
      target: "sandboxes"
    )
  end

  def broadcast_replace_to_dashboard
    # If sandbox is destroyed, remove it from the dashboard instead of replacing
    if status == "destroyed"
      broadcast_remove_to([user, "dashboard"], target: dom_id(self))
    else
      broadcast_replace_to(
        [user, "dashboard"],
        partial: "dashboard/sandbox",
        locals: { sandbox: self },
        target: dom_id(self)
      )
    end
  end

  def broadcast_remove_from_dashboard
    broadcast_remove_to([user, "dashboard"], target: dom_id(self))
  end

  def assign_ssh_port
    return if ssh_port.present?

    used_ports = Sandbox.where.not(status: "destroyed").pluck(:ssh_port)
    available = SSH_PORT_RANGE.to_a - used_ports
    self.ssh_port = available.first || raise("No SSH ports available")
  end
end
