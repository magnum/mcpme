# frozen_string_literal: true

module Mcpme
  # Published Anthropic egress ranges for MCP tool calls and connectors.
  # https://platform.claude.com/docs/en/api/ip-addresses
  module AnthropicIps
    DOCS_URL = "https://platform.claude.com/docs/en/api/ip-addresses"

    # Outbound from Anthropic infra (claude.ai MCP, web search/fetch, etc.).
    OUTBOUND_CIDRS = [
      "160.79.104.0/21", # IPv4
      "2607:6bc0::/48"    # IPv6
    ].freeze

    module_function

    def outbound_entries
      @outbound_entries ||= OUTBOUND_CIDRS.map { |cidr| IPAddr.new(cidr) }
    end

    def outbound?(ip)
      addr = IPAddr.new(ip.to_s)
      outbound_entries.any? { |entry| entry.include?(addr) }
    rescue IPAddr::Error
      false
    end
  end
end
