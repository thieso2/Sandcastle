class PersistedPath < ApplicationRecord
  belongs_to :user

  validates :path, presence: true, uniqueness: { scope: :user_id }
  validates :path, format: { without: %r{\A/}, message: "must be relative to home" }
  validate :no_traversal

  normalizes :path, with: ->(p) { p.to_s.strip.chomp("/") }

  private

  def no_traversal
    return if path.blank?
    if path.split("/").any? { |seg| seg == ".." || seg == "." || seg.empty? }
      errors.add(:path, "must not contain .., ., or empty segments")
    end
  end
end
