class SandboxAlias < ApplicationRecord
  KINDS = %w[sub fqdn].freeze
  LABEL = /\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/

  belongs_to :sandbox

  before_validation :normalize

  validates :kind, inclusion: { in: KINDS }
  validates :value, presence: true,
    uniqueness: { scope: [ :sandbox_id, :kind ], case_sensitive: false }
  validate :validate_fqdn_globally_unique
  validate :validate_value_format

  def fqdn
    case kind
    when "sub"
      base = sandbox && DnsManager.new.hostname_for(sandbox)
      base.present? ? "#{value}.#{base}" : nil
    when "fqdn"
      value
    end
  end

  private

  def normalize
    self.kind = kind.to_s.downcase.strip
    self.value = value.to_s.downcase.strip.chomp(".")
  end

  def validate_value_format
    return if value.blank? || !KINDS.include?(kind)

    parts = value.split(".")
    if parts.empty?
      errors.add(:value, "must contain at least one label")
      return
    end
    if kind == "fqdn" && parts.size < 2
      errors.add(:value, "must contain at least two labels for an fqdn")
      return
    end
    parts.each do |label|
      unless label.match?(LABEL) && label.length <= 63
        errors.add(:value, "contains invalid DNS label #{label.inspect}")
        return
      end
    end
  end

  def validate_fqdn_globally_unique
    return unless kind == "fqdn" && value.present?

    scope = SandboxAlias.where(kind: "fqdn", value: value)
    scope = scope.where.not(id: id) if persisted?
    errors.add(:value, "is already used by another sandbox") if scope.exists?
  end
end
