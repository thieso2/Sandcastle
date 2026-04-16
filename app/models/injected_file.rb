class InjectedFile < ApplicationRecord
  belongs_to :user
  encrypts :content

  validates :path, presence: true, uniqueness: { scope: :user_id }
  validates :path, format: { without: %r{\A/}, message: "must be relative to home" }
  validates :mode, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 0o777 }
  validate :no_traversal

  before_validation { self.mode ||= 0o600 }

  def content
    super
  rescue ActiveRecord::Encryption::Errors::Decryption
    nil
  end

  private

  def no_traversal
    return if path.blank?
    if path.split("/").any? { |seg| seg == ".." || seg == "." || seg.empty? }
      errors.add(:path, "must not contain .., ., or empty segments")
    end
  end
end
