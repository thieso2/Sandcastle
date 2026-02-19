class Snapshot < ApplicationRecord
  belongs_to :user

  validates :name, presence: true,
    uniqueness: { scope: :user_id },
    format: { with: /\A[a-z][a-z0-9_-]{0,62}\z/, message: "must be lowercase alphanumeric, hyphens, or underscores" }

  scope :for_user, ->(user) { where(user: user) }

  def layers
    layers = []
    layers << "container" if docker_image.present?
    layers << "home" if home_snapshot.present?
    layers << "data" if data_snapshot.present?
    layers
  end

  def total_size
    (docker_size || 0) + (home_size || 0) + (data_size || 0)
  end
end
