module Sandcastle
  def self.version
    @version ||= begin
      sha = ENV.fetch("BUILD_GIT_SHA") { `git rev-parse --short HEAD 2>/dev/null`.strip }
      dirty = ENV.fetch("BUILD_GIT_DIRTY", nil) || (`git status --porcelain 2>/dev/null`.strip.empty? ? "" : "-dirty")
      date = ENV.fetch("BUILD_DATE") { Time.now.strftime("%Y-%m-%d") }

      sha = "#{sha}#{dirty}" if dirty.present?

      parts = []
      parts << sha unless sha.empty?
      parts << date unless date.empty?
      parts.join(" / ")
    end
  end
end
