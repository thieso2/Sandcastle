class Route < ApplicationRecord
  belongs_to :sandbox

  validates :domain, presence: true, uniqueness: true,
    format: { with: /\A[a-z0-9]([a-z0-9.-]*[a-z0-9])?\.[a-z]{2,}\z/i, message: "must be a valid domain" },
    if: :http?
  validates :public_port, presence: true, uniqueness: true, if: :tcp?
  validates :mode, inclusion: { in: %w[http tcp] }
  validates :port, presence: true, inclusion: { in: 1..65535 }

  def http? = mode == "http"
  def tcp?  = mode == "tcp"

  def url
    http? ? "https://#{domain}" : nil
  end
end
