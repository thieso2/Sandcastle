class SandboxMount < ApplicationRecord
  MOUNT_TYPES = %w[home data persisted_path].freeze
  STORAGE_MODES = %w[direct snapshot].freeze
  STATES = %w[active committed discarded].freeze

  belongs_to :sandbox

  validates :mount_type, presence: true, inclusion: { in: MOUNT_TYPES }
  validates :storage_mode, presence: true, inclusion: { in: STORAGE_MODES }
  validates :state, presence: true, inclusion: { in: STATES }
  validates :target_path, :master_path, :source_path, presence: true
  validates :target_path, uniqueness: { scope: :sandbox_id }
  validate :absolute_paths
  validate :snapshot_paths_present
  validate :logical_path_shape

  normalizes :logical_path, with: ->(p) { p.to_s.strip.chomp("/").presence }
  normalizes :target_path, :master_path, :source_path, :base_path, :work_path,
    with: ->(p) { p.to_s.strip.chomp("/") }

  def snapshot?
    storage_mode == "snapshot"
  end

  def direct?
    storage_mode == "direct"
  end

  def bind_spec
    "#{source_path}:#{target_path}"
  end

  private

  def absolute_paths
    {
      target_path: target_path,
      master_path: master_path,
      source_path: source_path,
      base_path: base_path,
      work_path: work_path
    }.each do |attribute, value|
      next if value.blank?
      errors.add(attribute, "must be absolute") unless value.start_with?("/")
    end
  end

  def snapshot_paths_present
    return unless snapshot?

    errors.add(:base_path, "must be present for snapshot mounts") if base_path.blank?
    errors.add(:work_path, "must be present for snapshot mounts") if work_path.blank?
  end

  def logical_path_shape
    return if logical_path.blank?
    if logical_path.start_with?("/")
      errors.add(:logical_path, "must be relative")
    end
    if logical_path.split("/").any? { |seg| seg == ".." || seg.empty? }
      errors.add(:logical_path, "must not contain .. or empty segments")
    end
  end
end
