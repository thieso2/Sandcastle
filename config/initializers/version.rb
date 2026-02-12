module Sandcastle
  def self.version
    @version ||= begin
      tag = ENV.fetch("BUILD_VERSION", nil)
      sha = ENV.fetch("BUILD_GIT_SHA") { `git rev-parse --short HEAD 2>/dev/null`.strip }
      dirty = ENV.fetch("BUILD_GIT_DIRTY", nil) || (`git status --porcelain 2>/dev/null`.strip.empty? ? "" : "-dirty")

      sha = "#{sha}#{dirty}" if dirty.present?

      if tag.present?
        sha.present? ? "#{tag} (#{sha})" : tag
      elsif sha.present?
        date = ENV.fetch("BUILD_DATE") { Time.now.strftime("%Y-%m-%d") }
        "dev (#{sha} / #{date})"
      else
        "dev"
      end
    end
  end
end
