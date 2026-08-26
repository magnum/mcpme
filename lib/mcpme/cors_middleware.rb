# frozen_string_literal: true

module Mcpme
  # CORS for ChatGPT web MCP/OAuth. Native clients (Claude, ChatGPT Mac) ignore these;
  # the browser connector on chatgpt.com requires a successful OPTIONS preflight.
  class CorsMiddleware
    METHODS = "GET, POST, DELETE, OPTIONS"
    HEADERS = "Authorization, Content-Type, Accept, MCP-Protocol-Version, Mcp-Session-Id, Last-Event-ID"
    EXPOSE = "WWW-Authenticate, Mcp-Session-Id"

    def initialize(app)
      @app = app
    end

    def call(env)
      if env["REQUEST_METHOD"] == "OPTIONS" && cors_path?(env["PATH_INFO"].to_s)
        return [
          204,
          cors_headers.merge("content-length" => "0"),
          []
        ]
      end

      status, headers, body = @app.call(env)
      [status, headers.merge(cors_headers), body]
    end

    private

    def cors_path?(path)
      return true if path == "/mcp" || path.start_with?("/mcp/")
      return true if path == "/" || path.empty?
      return true if path.start_with?("/.well-known/")
      return true if %w[/authorize /token /register].include?(path)

      false
    end

    def cors_headers
      {
        "access-control-allow-origin" => "*",
        "access-control-allow-methods" => METHODS,
        "access-control-allow-headers" => HEADERS,
        "access-control-expose-headers" => EXPOSE,
        "access-control-max-age" => "86400"
      }
    end
  end
end
