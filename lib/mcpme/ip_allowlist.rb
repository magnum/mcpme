# frozen_string_literal: true

require "fileutils"
require "ipaddr"

module Mcpme
  # Persistent allowlist of remote IPs / CIDR ranges (one entry per line).
  class IpAllowlist
    def initialize(path:)
      @path = path
      @mutex = Mutex.new
      ensure_file!
    end

    def allowed?(ip)
      addr = IPAddr.new(ip.to_s)
      @mutex.synchronize do
        entries.any? { |entry| entry.include?(addr) }
      end
    rescue IPAddr::Error
      false
    end

    # Returns true if a new line was written, false if already present / covered.
    def add!(ip)
      normalized = normalize_entry(ip)
      addr = IPAddr.new(normalized)
      @mutex.synchronize do
        return false if covered_by_entries?(addr)

        FileUtils.mkdir_p(File.dirname(@path))
        File.open(@path, "a") do |file|
          file.puts(normalized)
          file.flush
        end
        true
      end
    end

    def exact_count(ip)
      normalized = normalize_entry(ip)
      @mutex.synchronize { read_lines.count { |line| line == normalized } }
    rescue IPAddr::Error
      0
    end

    private

    def covered_by_entries?(addr)
      entries.any? { |entry| entry.include?(addr) }
    end

    def normalize_entry(ip)
      addr = IPAddr.new(ip.to_s)
      prefix = addr.prefix
      prefix ? "#{addr}/#{prefix}" : addr.to_s
    end

    def ensure_file!
      return if File.file?(@path)

      FileUtils.mkdir_p(File.dirname(@path))
      File.write(
        @path,
        <<~TXT
          # Allowed remote IPs for mcpme (one per line).
          # Supports single addresses and CIDR netmasks, e.g.:
          # 203.0.113.10
          # 198.51.100.0/24
          #
          # An IP is added here when you confirm it from the Pushover link.
        TXT
      )
    end

    def entries
      read_lines.filter_map do |line|
        IPAddr.new(line)
      rescue IPAddr::Error
        nil
      end
    end

    def read_lines
      return [] unless File.file?(@path)

      File.readlines(@path, chomp: true).filter_map do |line|
        stripped = line.strip
        next if stripped.empty? || stripped.start_with?("#")

        stripped
      end
    end
  end
end
