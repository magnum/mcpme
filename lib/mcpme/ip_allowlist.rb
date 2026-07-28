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
      OpenaiIps.load!
      seed_provider_defaults!
    end

    def allowed?(ip)
      addr = IPAddr.new(ip.to_s)
      return true if AnthropicIps.outbound?(ip)
      return true if OpenaiIps.outbound?(ip)

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

    PROVIDERS = [
      {
        marker: "Anthropic / Claude outbound",
        comment: "# Anthropic / Claude outbound (auto-seeded, #{AnthropicIps::DOCS_URL})",
        cidrs: -> { AnthropicIps::OUTBOUND_CIDRS }
      },
      {
        marker: "OpenAI / ChatGPT connectors",
        comment: "# OpenAI / ChatGPT connectors (auto-loaded, #{OpenaiIps::DOCS_URL})",
        cidrs: -> { [] } # checked via OpenaiIps.outbound? + data/openai_connectors_cidrs.txt
      }
    ].freeze

    def seed_provider_defaults!
      PROVIDERS.each do |provider|
        ensure_provider_comment!(provider)
        provider[:cidrs].call.each do |cidr|
          next unless add!(cidr)

          Mcpme::Logger.log("allowlist: added #{provider[:marker]} #{cidr}", level: "IP")
        end
      end
    end

    def ensure_provider_comment!(provider)
      return if file_includes_marker?(provider[:marker])

      append_lines("", provider[:comment])
    end

    def file_includes_marker?(marker)
      return false unless File.file?(@path)

      File.read(@path).include?(marker)
    end

    def append_lines(*lines)
      FileUtils.mkdir_p(File.dirname(@path))
      File.open(@path, "a") do |file|
        lines.each { |line| file.puts(line) }
        file.flush
      end
    end

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
          # Anthropic and OpenAI connector ranges are loaded automatically on startup.
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
