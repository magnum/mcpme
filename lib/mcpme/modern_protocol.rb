# frozen_string_literal: true

module Mcpme
  # ChatGPT web (openai-mcp) speaks MCP 2026-07-28: it probes `server/discover`
  # and then lists tools without the legacy `initialize` handshake. The mcp 0.25
  # gem answers discover with only 2025 versions, so ChatGPT treats the 200 as a
  # failed connector refresh. Shape the modern result here until we can bump the gem.
  module ModernProtocol
    MODERN_PROTOCOL_VERSION = "2026-07-28"
    PROTOCOL_VERSION_META_KEY = "io.modelcontextprotocol/protocolVersion"
    SERVER_INFO_META_KEY = "io.modelcontextprotocol/serverInfo"
    CACHEABLE_RESULT_KEYS = %w[tools prompts resources resourceTemplates contents].freeze

    module_function

    def install!(server)
      original = server.method(:handle_json)
      server.define_singleton_method(:handle_json) do |request, session: nil|
        Mcpme::ModernProtocol.handle(server, request) { original.call(request, session: session) }
      end
      server
    end

    def handle(server, request)
      parsed = JSON.parse(request)
      return yield unless parsed.is_a?(Hash)

      if parsed["method"] == "server/discover"
        return jsonrpc_result(parsed["id"], modern_discover_result(server))
      end

      response = yield
      return response unless response.is_a?(String) && modern_mcp_request?(parsed)

      stamp_modern_result(response)
    rescue JSON::ParserError
      yield
    end

    def modern_mcp_request?(parsed)
      parsed.dig("params", "_meta", PROTOCOL_VERSION_META_KEY) == MODERN_PROTOCOL_VERSION
    end

    def modern_discover_result(server)
      {
        "resultType" => "complete",
        "supportedVersions" => [MODERN_PROTOCOL_VERSION],
        "capabilities" => { "tools" => {} },
        "instructions" => server.instructions,
        "ttlMs" => 0,
        "cacheScope" => "private",
        "_meta" => {
          SERVER_INFO_META_KEY => {
            "name" => server.name,
            "version" => server.version
          }
        }
      }
    end

    def jsonrpc_result(id, result)
      JSON.generate("jsonrpc" => "2.0", "id" => id, "result" => result)
    end

    def stamp_modern_result(json_string)
      payload = JSON.parse(json_string)
      result = payload["result"]
      return json_string unless result.is_a?(Hash)

      result["resultType"] ||= "complete"
      if CACHEABLE_RESULT_KEYS.any? { |key| result.key?(key) }
        result["ttlMs"] ||= 0
        result["cacheScope"] ||= "private"
      end
      payload["result"] = result
      JSON.generate(payload)
    rescue JSON::ParserError
      json_string
    end
  end
end
