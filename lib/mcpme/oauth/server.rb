# frozen_string_literal: true

module Mcpme
  module OAuth
    # Minimal OAuth 2.1 Authorization Server for MCP clients:
    # - Protected Resource Metadata (RFC 9728)
    # - Authorization Server Metadata (RFC 8414)
    # - Dynamic Client Registration (RFC 7591)
    # - Authorization Code + PKCE (S256)
    # - Login validates OAUTH_USER / OAUTH_PASSWORD from .env
    class Server
      CODE_TTL = 300

      def initialize(config:, store:)
        @config = config
        @store = store
      end

      def call(env)
        request = Rack::Request.new(env)

        case [request.request_method, request.path_info]
        when ["GET", "/.well-known/oauth-protected-resource"],
             ["GET", "/.well-known/oauth-protected-resource/mcp"]
          json(protected_resource_metadata)
        when ["GET", "/.well-known/oauth-authorization-server"]
          json(authorization_server_metadata)
        when ["POST", "/register"]
          register_client(request)
        when ["GET", "/authorize"]
          render_login(request)
        when ["POST", "/authorize"]
          handle_authorize(request)
        when ["POST", "/token"]
          handle_token(request)
        else
          not_found
        end
      rescue JSON::ParserError
        error_response(400, "invalid_request", "Invalid JSON body")
      end

      def validate_bearer(token)
        return nil if token.nil? || token.empty?

        record = @store.find_access_token(token)
        return nil unless record

        if record[:resource] && !resource_allowed?(record[:resource])
          return nil
        end

        record
      end

      def www_authenticate_header
        metadata_url = "#{@config.base_url}/.well-known/oauth-protected-resource"
        %(Bearer realm="mcp", resource_metadata="#{metadata_url}")
      end

      def resource_allowed?(resource)
        aliases = [
          @config.mcp_resource_url,
          @config.base_url.chomp("/"),
          "#{@config.base_url.chomp("/")}/mcp"
        ].uniq
        aliases.include?(resource.to_s.chomp("/")) || aliases.include?(resource.to_s)
      end

      private

      def protected_resource_metadata
        {
          resource: @config.mcp_resource_url,
          authorization_servers: [@config.issuer],
          scopes_supported: ["mcp:tools"],
          bearer_methods_supported: ["header"],
          resource_documentation: "#{@config.base_url}/",
          resource_name: "mcpme",
          resource_description: "Esegue comandi shell sul PC dell'utente dove gira il server mcpme."
        }
      end

      def authorization_server_metadata
        {
          issuer: @config.issuer,
          authorization_endpoint: "#{@config.base_url}/authorize",
          token_endpoint: "#{@config.base_url}/token",
          registration_endpoint: "#{@config.base_url}/register",
          response_types_supported: ["code"],
          grant_types_supported: ["authorization_code", "refresh_token"],
          code_challenge_methods_supported: ["S256"],
          token_endpoint_auth_methods_supported: ["none"],
          scopes_supported: ["mcp:tools"],
          authorization_response_iss_parameter_supported: true
        }
      end

      def register_client(request)
        body = JSON.parse(request.body.read)
        redirect_uris = Array(body["redirect_uris"])
        if redirect_uris.empty?
          return error_response(400, "invalid_client_metadata", "redirect_uris is required")
        end

        client = @store.register_client(body)
        json(
          {
            client_id: client[:client_id],
            client_id_issued_at: client[:created_at].to_i,
            redirect_uris: client[:redirect_uris],
            grant_types: client[:grant_types],
            response_types: client[:response_types],
            token_endpoint_auth_method: client[:token_endpoint_auth_method]
          },
          status: 201
        )
      end

      def render_login(request)
        params = request.params
        missing = %w[response_type client_id redirect_uri code_challenge code_challenge_method].select do |key|
          params[key].to_s.empty?
        end
        return html_error(400, "Missing parameters: #{missing.join(', ')}") unless missing.empty?
        return html_error(400, "response_type must be code") unless params["response_type"] == "code"
        return html_error(400, "code_challenge_method must be S256") unless params["code_challenge_method"] == "S256"

        client = @store.find_client(params["client_id"])
        return html_error(400, "Unknown client_id") unless client
        unless client[:redirect_uris].include?(params["redirect_uri"])
          return html_error(400, "redirect_uri is not registered for this client")
        end

        html(login_page(params, error: nil))
      end

      def handle_authorize(request)
        params = request.params
        username = params["username"].to_s
        password = params["password"].to_s

        unless @config.credentials_match?(username, password)
          return html(login_page(params, error: "Invalid username or password"), status: 401)
        end

        client = @store.find_client(params["client_id"])
        return html_error(400, "Unknown client_id") unless client
        unless client[:redirect_uris].include?(params["redirect_uri"])
          return html_error(400, "redirect_uri is not registered for this client")
        end

        code = SecureRandom.urlsafe_base64(32)
        @store.save_auth_code(
          code,
          {
            client_id: params["client_id"],
            redirect_uri: params["redirect_uri"],
            code_challenge: params["code_challenge"],
            code_challenge_method: params["code_challenge_method"],
            scope: params["scope"].to_s.empty? ? "mcp:tools" : params["scope"],
            resource: params["resource"].to_s.empty? ? @config.mcp_resource_url : params["resource"],
            username: username,
            expires_at: Time.now.utc + CODE_TTL
          }
        )

        redirect = URI(params["redirect_uri"])
        query = Rack::Utils.parse_query(redirect.query.to_s)
        query["code"] = code
        query["state"] = params["state"] if params["state"] && !params["state"].empty?
        query["iss"] = @config.issuer
        redirect.query = Rack::Utils.build_query(query)

        [303, { "location" => redirect.to_s, "cache-control" => "no-store" }, []]
      end

      def handle_token(request)
        params = form_or_json(request)
        grant_type = params["grant_type"].to_s

        case grant_type
        when "authorization_code"
          exchange_authorization_code(params)
        when "refresh_token"
          exchange_refresh_token(params)
        else
          error_response(400, "unsupported_grant_type", "Supported: authorization_code, refresh_token")
        end
      end

      def exchange_authorization_code(params)
        code = params["code"].to_s
        record = @store.consume_auth_code(code)
        return error_response(400, "invalid_grant", "Invalid or expired authorization code") unless record
        if record[:expires_at] && Time.now.utc >= record[:expires_at]
          return error_response(400, "invalid_grant", "Authorization code expired")
        end
        if params["client_id"].to_s != record[:client_id]
          return error_response(400, "invalid_grant", "client_id mismatch")
        end
        if params["redirect_uri"].to_s != record[:redirect_uri]
          return error_response(400, "invalid_grant", "redirect_uri mismatch")
        end
        unless valid_pkce?(params["code_verifier"].to_s, record[:code_challenge])
          return error_response(400, "invalid_grant", "PKCE verification failed")
        end

        issue_tokens(
          client_id: record[:client_id],
          scope: record[:scope],
          resource: record[:resource],
          username: record[:username]
        )
      end

      def exchange_refresh_token(params)
        refresh = @store.consume_refresh_token(params["refresh_token"].to_s)
        return error_response(400, "invalid_grant", "Invalid refresh token") unless refresh
        if refresh[:expires_at] && Time.now.utc >= refresh[:expires_at]
          return error_response(400, "invalid_grant", "Refresh token expired")
        end
        if params["client_id"].to_s != refresh[:client_id]
          return error_response(400, "invalid_grant", "client_id mismatch")
        end

        issue_tokens(
          client_id: refresh[:client_id],
          scope: refresh[:scope],
          resource: refresh[:resource],
          username: refresh[:username]
        )
      end

      def issue_tokens(client_id:, scope:, resource:, username:)
        access_token = SecureRandom.urlsafe_base64(32)
        refresh_token = SecureRandom.urlsafe_base64(32)
        now = Time.now.utc

        @store.save_access_token(
          access_token,
          {
            client_id: client_id,
            scope: scope,
            resource: resource,
            username: username,
            expires_at: now + @config.oauth_token_ttl_seconds
          }
        )
        @store.save_refresh_token(
          refresh_token,
          {
            client_id: client_id,
            scope: scope,
            resource: resource,
            username: username,
            expires_at: now + @config.oauth_token_ttl_seconds
          }
        )

        json(
          {
            access_token: access_token,
            token_type: "Bearer",
            expires_in: @config.oauth_token_ttl_seconds,
            refresh_token: refresh_token,
            scope: scope
          }
        )
      end

      def valid_pkce?(verifier, challenge)
        return false if verifier.empty? || challenge.to_s.empty?

        digest = Digest::SHA256.digest(verifier)
        computed = Base64.urlsafe_encode64(digest, padding: false)
        Rack::Utils.secure_compare(computed, challenge)
      end

      def form_or_json(request)
        content_type = request.content_type.to_s
        if content_type.include?("application/json")
          JSON.parse(request.body.read)
        else
          request.params
        end
      end

      def login_page(params, error:)
        hidden = %w[
          response_type client_id redirect_uri scope state
          code_challenge code_challenge_method resource
        ].map do |key|
          value = CGI.escapeHTML(params[key].to_s)
          %(<input type="hidden" name="#{key}" value="#{value}">)
        end.join("\n")

        error_html = error ? %(<p class="error">#{CGI.escapeHTML(error)}</p>) : ""

        <<~HTML
          <!DOCTYPE html>
          <html lang="en">
          <head>
            <meta charset="utf-8">
            <title>mcpme OAuth Login</title>
            <style>
              body { font-family: ui-sans-serif, system-ui, sans-serif; max-width: 28rem; margin: 4rem auto; padding: 0 1rem; }
              label { display: block; margin-top: 1rem; font-weight: 600; }
              input[type=text], input[type=password] { width: 100%; padding: 0.5rem; margin-top: 0.25rem; box-sizing: border-box; }
              button { margin-top: 1.25rem; padding: 0.6rem 1rem; width: 100%; cursor: pointer; }
              .error { color: #b00020; }
              .hint { color: #555; font-size: 0.9rem; }
            </style>
          </head>
          <body>
            <h1>mcpme</h1>
            <p class="hint">Accesso OAuth per l'MCP che esegue comandi shell sul tuo PC. Usa OAUTH_USER / OAUTH_PASSWORD dal file .env.</p>
            #{error_html}
            <form method="post" action="/authorize">
              #{hidden}
              <label>Username
                <input type="text" name="username" autocomplete="username" required autofocus>
              </label>
              <label>Password
                <input type="password" name="password" autocomplete="current-password" required>
              </label>
              <button type="submit">Authorize</button>
            </form>
          </body>
          </html>
        HTML
      end

      def json(payload, status: 200)
        [
          status,
          {
            "content-type" => "application/json",
            "cache-control" => "no-store"
          },
          [JSON.generate(payload)]
        ]
      end

      def html(body, status: 200)
        [status, { "content-type" => "text/html; charset=utf-8", "cache-control" => "no-store" }, [body]]
      end

      def html_error(status, message)
        html("<!DOCTYPE html><html><body><h1>Error</h1><p>#{CGI.escapeHTML(message)}</p></body></html>", status: status)
      end

      def error_response(status, error, description)
        json({ error: error, error_description: description }, status: status)
      end

      def not_found
        [404, { "content-type" => "text/plain" }, ["Not Found"]]
      end
    end
  end
end
