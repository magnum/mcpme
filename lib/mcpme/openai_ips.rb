# frozen_string_literal: true

require "ipaddr"
require "json"
require "net/http"
require "fileutils"

module Mcpme
  # ChatGPT connectors / plugins / GPT Actions egress ranges.
  # https://developers.openai.com/api/docs/guides/ip-addresses
  module OpenaiIps
    MANIFEST_URL = "https://openai.com/chatgpt-connectors.json"
    DOCS_URL = "https://developers.openai.com/api/docs/guides/ip-addresses"
    DEFAULT_CACHE = "data/openai_connectors_cidrs.txt"

    module_function

    def load!(cache_path: File.expand_path(DEFAULT_CACHE, Dir.pwd))
      @cache_path = cache_path
      manifest = fetch_manifest || read_cached_manifest(cache_path)
      if manifest
        apply_manifest!(manifest, cache_path)
      else
        load_entries_from_cache(cache_path)
        Mcpme::Logger.log(
          "OpenAI connectors: using cached ranges only (#{@entries&.size || 0}) — manifest fetch failed",
          level: "WARN"
        )
      end
      @entries || []
    end

    def outbound?(ip)
      return false if @entries.nil? || @entries.empty?

      addr = IPAddr.new(ip.to_s)
      @entries.any? { |entry| entry.include?(addr) }
    rescue IPAddr::Error
      false
    end

    def cidrs
      (@entries || []).map do |entry|
        prefix = entry.prefix
        prefix ? "#{entry}/#{prefix}" : entry.to_s
      end
    end

    def creation_time
      @creation_time
    end

    def loaded?
      !@entries.nil? && !@entries.empty?
    end

    def fetch_manifest
      uri = URI(MANIFEST_URL)
      response = Net::HTTP.get_response(uri)
      unless response.is_a?(Net::HTTPSuccess)
        Mcpme::Logger.log("OpenAI manifest HTTP #{response.code}", level: "WARN")
        return nil
      end

      JSON.parse(response.body)
    rescue StandardError => e
      Mcpme::Logger.log("OpenAI manifest fetch failed: #{e.class}: #{e.message}", level: "WARN")
      nil
    end

    def read_cached_manifest(cache_path)
      return nil unless File.file?(cache_path)

      lines = File.readlines(cache_path, chomp: true)
      meta = lines.find { |line| line.start_with?("# creationTime:") }
      return nil unless meta

      prefixes = lines.filter_map do |line|
        stripped = line.strip
        next if stripped.empty? || stripped.start_with?("#")

        { "ipv4Prefix" => stripped }
      end

      {
        "creationTime" => meta.sub("# creationTime:", "").strip,
        "prefixes" => prefixes
      }
    end

    def apply_manifest!(manifest, cache_path)
      @creation_time = manifest["creationTime"]
      cidrs = manifest.fetch("prefixes", []).filter_map do |prefix|
        prefix["ipv4Prefix"] || prefix["ipv6Prefix"]
      end

      write_cache!(cache_path, @creation_time, cidrs)
      @entries = cidrs.filter_map { |cidr| IPAddr.new(cidr) }
      Mcpme::Logger.log(
        "OpenAI connectors: loaded #{@entries.size} ranges (manifest #{@creation_time})",
        level: "IP"
      )
    rescue StandardError => e
      Mcpme::Logger.log("OpenAI manifest parse failed: #{e.class}: #{e.message}", level: "ERROR")
      load_entries_from_cache(cache_path)
    end

    def write_cache!(cache_path, creation_time, cidrs)
      FileUtils.mkdir_p(File.dirname(cache_path))
      File.write(
        cache_path,
        ["# creationTime: #{creation_time}", "# #{DOCS_URL}", *cidrs, ""].join("\n")
      )
    end

    def load_entries_from_cache(cache_path)
      return unless File.file?(cache_path)

      lines = File.readlines(cache_path, chomp: true)
      meta_line = lines.find { |line| line.start_with?("# creationTime:") }
      @creation_time = meta_line&.sub("# creationTime:", "")&.strip

      @entries = lines.filter_map do |line|
        stripped = line.strip
        next if stripped.empty? || stripped.start_with?("#")

        IPAddr.new(stripped)
      rescue IPAddr::Error
        nil
      end
    end
  end
end
