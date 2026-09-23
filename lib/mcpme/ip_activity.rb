# frozen_string_literal: true

require "json"
require "fileutils"
require "time"

module Mcpme
  # Last time each remote IP ran a confirmed shell command.
  # A listed IP still needs a new Pushover confirm after confirm_idle_seconds.
  class IpActivity
    def initialize(path:, idle_seconds:)
      @path = path
      @idle_seconds = idle_seconds
      @mutex = Mutex.new
      @seen = {}
      load!
    end

    def fresh?(ip, now: Time.now.utc)
      seen = last_seen(ip)
      return false unless seen

      (now - seen) < @idle_seconds
    end

    def touched_after?(ip, mark)
      seen = last_seen(ip)
      seen && seen > mark
    end

    def touch!(ip, now: Time.now.utc)
      key = normalize(ip)
      @mutex.synchronize do
        @seen[key] = now.utc
        persist!
      end
    end

    private

    def last_seen(ip)
      @mutex.synchronize { @seen[normalize(ip)] }
    end

    def normalize(ip)
      RemoteIp.normalize(ip)
    end

    def load!
      return unless File.file?(@path)

      data = JSON.parse(File.read(@path))
      return unless data.is_a?(Hash)

      data.each do |ip, stamp|
        @seen[normalize(ip)] = Time.parse(stamp).utc
      end
      FileMode.restrict!(@path)
    rescue StandardError => e
      warn "mcpme ip activity load failed: #{e.class}: #{e.message}"
    end

    def persist!
      FileUtils.mkdir_p(File.dirname(@path))
      payload = @seen.transform_values { |time| time.utc.iso8601 }
      tmp = "#{@path}.tmp"
      File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
        file.write(JSON.generate(payload))
      end
      File.rename(tmp, @path)
      FileMode.restrict!(@path)
    end
  end
end
