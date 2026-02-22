class Invite < ApplicationRecord
  belongs_to :invited_by, class_name: "User"

  validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :token, presence: true, uniqueness: true

  normalizes :email, with: ->(e) { e.strip.downcase }

  before_validation :generate_token, on: :create
  before_create :set_default_expiry

  scope :pending, -> { where(accepted_at: nil).where("expires_at IS NULL OR expires_at > ?", Time.current) }
  scope :accepted, -> { where.not(accepted_at: nil) }
  scope :expired, -> { where(accepted_at: nil).where("expires_at IS NOT NULL AND expires_at <= ?", Time.current) }

  def accepted?
    accepted_at.present?
  end

  def expired?
    expires_at.present? && expires_at <= Time.current
  end

  def pending?
    !accepted? && !expired?
  end

  def status
    if accepted?
      "accepted"
    elsif expired?
      "expired"
    else
      "pending"
    end
  end

  def accept!
    update!(accepted_at: Time.current)
  end

  private

  def generate_token
    self.token ||= SecureRandom.urlsafe_base64(32)
  end

  def set_default_expiry
    self.expires_at ||= 7.days.from_now
  end
end
