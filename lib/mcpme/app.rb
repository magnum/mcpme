# frozen_string_literal: true

module Mcpme
  class App
    OAUTH_PATHS = [
      "/.well-known/oauth-protected-resource",
      "/.well-known/oauth-protected-resource/mcp",
      "/.well-known/oauth-authorization-server",
      "/.well-known/oauth-authorization-server/mcp",
      "/.well-known/openid-configuration",
      "/authorize",
      "/token",
      "/register"
    ].freeze

    def self.build(config: Config.load)
      store = OAuth::Store.new
      oauth = OAuth::Server.new(config: config, store: store)
      allowlist = IpAllowlist.new(path: File.expand_path(config.allowed_remote_ips_path, Dir.pwd))
      confirm = IpConfirm.new(config: config, allowlist: allowlist)
      pushover = Pushover.new(
        token: config.pushover_token,
        user: config.pushover_user,
        device: config.pushover_device
      )
      ip_gate = IpGate.new(config: config, allowlist: allowlist, confirm: confirm, pushover: pushover)
      mcp = McpServer.build(
        ip_gate: ip_gate,
        command_timeout: config.command_timeout_seconds,
        command_max_output_bytes: config.command_max_output_bytes
      )
      host = URI(config.base_url).host
      origin = config.base_url
      public = Mcpme::TunnelHelpers.public_hostname?(host)

      transport = MCP::Server::Transports::StreamableHTTPTransport.new(
        mcp,
        enable_json_response: true,
        # ChatGPT web lists tools after server/discover without Mcp-Session-Id.
        # Stateful mode returns 400 "Missing session ID"; Claude still works
        # with ephemeral per-request sessions in stateless mode.
        stateless: true,
        # Behind Cloudflare Tunnel the Host is the public hostname; Anthropic
        # origins won't match same-origin, so disable DNS-rebinding checks publicly.
        dns_rebinding_protection: !public,
        allowed_hosts: [host, "127.0.0.1", "localhost"].compact.uniq,
        allowed_origins: [
          origin,
          "https://claude.ai",
          "https://www.claude.ai",
          "https://claude.com",
          "https://www.claude.com",
          "https://chatgpt.com",
          "https://www.chatgpt.com",
          "https://chat.openai.com",
          "https://127.0.0.1:#{config.port}",
          "https://localhost:#{config.port}",
          "http://127.0.0.1:#{config.port}",
          "http://localhost:#{config.port}"
        ].uniq
      )

      new(config: config, oauth: oauth, transport: transport, confirm: confirm)
    end

    def initialize(config:, oauth:, transport:, confirm:)
      @config = config
      @oauth = oauth
      @transport = transport
      @confirm = confirm
      @logger = AuthMiddleware.new(
        method(:dispatch),
        oauth: oauth
      )
    end

    def call(env)
      @logger.call(env)
    end

    private

    def dispatch(env)
      request = Rack::Request.new(env)
      path = request.path_info

      if path.start_with?("/confirm-ip/")
        return @confirm.call(env)
      end

      if OAUTH_PATHS.include?(path)
        return @oauth.call(env)
      end

      if request.options? && (path == "/mcp" || path.start_with?("/mcp/") || path_root?(path))
        return [204, { "content-length" => "0" }, []]
      end

      if mcp_endpoint?(request)
        RemoteIp.current = RemoteIp.from_request(request)
        begin
          if request.post?
            raw = request.body.read
            env["mcpme.request_body"] = raw
            request.body.rewind if request.body.respond_to?(:rewind)
            env["rack.input"] = StringIO.new(raw)
          end
          return @transport.call(env)
        ensure
          RemoteIp.current = nil
        end
      end

      if path_root?(path) && (request.get? || request.head?)
        return root_response
      end

      [404, { "content-type" => "text/plain" }, ["Not Found"]]
    end

    def mcp_endpoint?(request)
      path = request.path_info
      return true if path == "/mcp" || path.start_with?("/mcp/")

      return false unless path_root?(path)

      case request.request_method
      when "POST", "DELETE"
        true
      when "GET", "HEAD"
        accept = request.get_header("HTTP_ACCEPT").to_s.downcase
        accept.include?("text/event-stream") ||
          !request.get_header("HTTP_MCP_PROTOCOL_VERSION").to_s.empty? ||
          (accept.include?("application/json") && !accept.include?("text/html"))
      else
        false
      end
    end

    def path_root?(path)
      path.nil? || path.empty? || path == "/"
    end

    def root_response
      body = {
        name: "mcpme",
        version: Mcpme::VERSION,
        description: "MCP che permette di eseguire comandi shell sul PC dell'utente (dove gira mcpme).",
        mcp_endpoint: @config.mcp_resource_url,
        oauth: {
          protected_resource_metadata: "#{@config.base_url}/.well-known/oauth-protected-resource",
          authorization_server_metadata: "#{@config.base_url}/.well-known/oauth-authorization-server"
        }
      }
      [200, { "content-type" => "application/json" }, [JSON.generate(body)]]
    end
  end
end
