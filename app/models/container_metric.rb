class ContainerMetric < ApplicationRecord
  belongs_to :sandbox

  scope :recent, -> { where("recorded_at > ?", 30.minutes.ago).order(:recorded_at) }
end
