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
      normalized = IPAddr.new(ip.to_s).to_s
      addr = IPAddr.new(normalized)
      @mutex.synchronize do
        # Exact line or already covered by an existing CIDR / address.
        return false if entries.any? { |entry| entry.include?(addr) }

        FileUtils.mkdir_p(File.dirname(@path))
        File.open(@path, "a") do |file|
          file.puts(normalized)
          file.flush
        end
        true
      end
    end

    def exact_count(ip)
      normalized = IPAddr.new(ip.to_s).to_s
      @mutex.synchronize { read_lines.count { |line| line == normalized } }
    rescue IPAddr::Error
      0
    end

    private

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
