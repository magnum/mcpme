# frozen_string_literal: true

module Mcpme
  # Requires a valid Bearer access token on MCP protocol endpoints.
  class AuthMiddleware
    def initialize(app, oauth:)
      @app = app
      @oauth = oauth
    end

    def call(env)
      request = Rack::Request.new(env)
      return @app.call(env) unless requires_auth?(request)

      token = bearer_token(request)
      record = @oauth.validate_bearer(token)
      unless record
        return [
          401,
          {
            "content-type" => "application/json",
            "www-authenticate" => @oauth.www_authenticate_header,
            "cache-control" => "no-store"
          },
          [JSON.generate({ error: "unauthorized", error_description: "Bearer token required" })]
        ]
      end

      env["mcpme.auth"] = record
      @app.call(env)
    end

    private

    def requires_auth?(request)
      path = request.path_info
      return true if path == "/mcp" || path.start_with?("/mcp/")

      # Claude may POST JSON-RPC initialize to "/" after OAuth.
      return true if root_mcp_request?(request)

      false
    end

    def root_mcp_request?(request)
      return false unless path_root?(request.path_info)

      case request.request_method
      when "POST", "DELETE"
        true
      when "GET", "HEAD"
        mcpish_accept?(request)
      else
        false
      end
    end

    def path_root?(path)
      path.nil? || path.empty? || path == "/"
    end

    def mcpish_accept?(request)
      accept = request.get_header("HTTP_ACCEPT").to_s.downcase
      return true if accept.include?("text/event-stream")
      return true if request.get_header("HTTP_MCP_PROTOCOL_VERSION")
      return true if accept.include?("application/json") && !accept.include?("text/html")

      false
    end

    def bearer_token(request)
      header = request.get_header("HTTP_AUTHORIZATION").to_s
      return nil unless header.match?(/\ABearer\s+/i)

      header.sub(/\ABearer\s+/i, "").strip
    end
  end
end
