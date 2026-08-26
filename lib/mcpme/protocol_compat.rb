# frozen_string_literal: true

module Mcpme
  # ChatGPT web (openai-mcp) speaks MCP 2026-07-28 and lists tools without a
  # Streamable HTTP session. The mcp 0.25 gem only advertises 2025 versions in
  # SUPPORTED_STABLE_PROTOCOL_VERSIONS and rejects sessionless POSTs in stateful
  # mode. Extend both so ChatGPT and Claude can share the same transport.
  module ProtocolCompat
    CHATGPT_PROTOCOL_VERSION = ModernProtocol::MODERN_PROTOCOL_VERSION

    module_function

    def install!
      extend_supported_versions!
      true
    end

    def extend_supported_versions!
      versions = MCP::Configuration::SUPPORTED_STABLE_PROTOCOL_VERSIONS
      return if versions.include?(CHATGPT_PROTOCOL_VERSION)

      expanded = (versions + [CHATGPT_PROTOCOL_VERSION]).freeze
      MCP::Configuration.send(:remove_const, :SUPPORTED_STABLE_PROTOCOL_VERSIONS)
      MCP::Configuration.const_set(:SUPPORTED_STABLE_PROTOCOL_VERSIONS, expanded)
      Mcpme::Logger.log(
        "MCP protocol compat: accepting #{CHATGPT_PROTOCOL_VERSION} (ChatGPT web)",
        level: "INFO"
      )
    end
  end
end
