class Sandbox < ApplicationRecord
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

  private

  def assign_ssh_port
    return if ssh_port.present?

    used_ports = Sandbox.where.not(status: "destroyed").pluck(:ssh_port)
    available = SSH_PORT_RANGE.to_a - used_ports
    self.ssh_port = available.first || raise("No SSH ports available")
  end
end
