class IgnoredPath < ApplicationRecord
  belongs_to :user

  validates :path, presence: true, uniqueness: { scope: :user_id }
end
