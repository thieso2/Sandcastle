class Route < ApplicationRecord
  belongs_to :sandbox

  validates :domain,
    presence: true,
    uniqueness: true,
    format: { with: /\A[a-z0-9]([a-z0-9.-]*[a-z0-9])?\.[a-z]{2,}\z/i, message: "must be a valid domain" }
  validates :port, presence: true, inclusion: { in: 1..65535 }

  def url
    "https://#{domain}"
  end
end
