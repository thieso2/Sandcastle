class ApplicationJob < ActiveJob::Base
  # Automatically retry jobs that encountered a deadlock
  # retry_on ActiveRecord::Deadlocked

  # Most jobs are safe to ignore if the underlying records are no longer available
  # discard_on ActiveJob::DeserializationError

  around_perform do |job, block|
    args_summary = job.arguments.map { |a| a.is_a?(Hash) ? a.map { |k, v| "#{k}=#{v}" }.join(" ") : a.to_s }.join(", ")
    logger.info { "[Job] #{job.class.name} started (#{args_summary})" }
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    block.call
    elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(1)
    logger.info { "[Job] #{job.class.name} completed in #{elapsed}s" }
  rescue => e
    elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(1)
    logger.error { "[Job] #{job.class.name} FAILED after #{elapsed}s: #{e.class}: #{e.message}" }
    raise
  end
end
