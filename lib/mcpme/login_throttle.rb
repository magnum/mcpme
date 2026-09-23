# frozen_string_literal: true

module Mcpme
  # Locks an IP out of the OAuth login form after repeated failures.
  class LoginThrottle
    def initialize(max_failures:, lockout_seconds:)
      @max_failures = max_failures
      @lockout_seconds = lockout_seconds
      @mutex = Mutex.new
      @buckets = {}
    end

    def blocked?(ip)
      @mutex.synchronize do
        bucket = @buckets[ip]
        return false unless bucket
        return false unless bucket[:locked_until]

        if Time.now.utc < bucket[:locked_until]
          true
        else
          @buckets.delete(ip)
          false
        end
      end
    end

    def record_failure(ip)
      @mutex.synchronize do
        bucket = @buckets[ip] ||= { failures: 0, locked_until: nil }
        bucket[:failures] += 1
        bucket[:locked_until] = Time.now.utc + @lockout_seconds if bucket[:failures] >= @max_failures
        bucket[:failures]
      end
    end

    def reset(ip)
      @mutex.synchronize { @buckets.delete(ip) }
    end
  end
end
