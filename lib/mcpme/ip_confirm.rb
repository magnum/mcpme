# frozen_string_literal: true

require "openssl"
require "cgi"
require "ipaddr"

module Mcpme
  # HMAC signatures and HTML pages for remote IP confirmation.
  class IpConfirm
    def initialize(config:, allowlist:, activity: nil)
      @config = config
      @allowlist = allowlist
      @activity = activity
    end

    def signature_for(ip, expires_at)
      OpenSSL::HMAC.hexdigest("SHA256", @config.secret_key, "#{normalize(ip)}\n#{expires_at.to_i}")
    end

    def link_valid?(ip, signature, expires_at)
      return false unless expires_at.to_s.match?(/\A[0-9]+\z/)

      exp = expires_at.to_i
      return false if exp <= Time.now.to_i

      expected = signature_for(ip, exp)
      return false if signature.nil? || signature.empty?
      return false unless expected.bytesize == signature.bytesize

      Rack::Utils.secure_compare(expected, signature)
    end

    def confirm_url(ip, now: Time.now)
      normalized = normalize(ip)
      expires_at = now.to_i + @config.confirm_link_ttl_seconds
      signature = signature_for(normalized, expires_at)
      "#{@config.base_url}/confirm-ip/#{CGI.escape(normalized)}?expires=#{expires_at}&signature=#{signature}"
    end

    def call(env)
      request = Rack::Request.new(env)
      path = request.path_info.to_s
      match = path.match(%r{\A/confirm-ip/([^/]+)(?:/(confirm|cancel))?\z})
      return [404, { "content-type" => "text/plain" }, ["Not Found"]] unless match

      ip = CGI.unescape(match[1].to_s)
      action = match[2]
      signature = request.params["signature"].to_s
      expires_at = request.params["expires"].to_s

      unless RemoteIp.valid?(ip) && link_valid?(ip, signature, expires_at)
        return html_response(403, error_page("Invalid or expired confirmation link."))
      end

      ip = RemoteIp.normalize(ip)

      case action
      when nil
        html_response(200, prompt_page(ip, signature, expires_at))
      when "confirm"
        @allowlist.add!(ip)
        @activity&.touch!(ip)
        Mcpme::Logger.log("confirmed remote ip #{ip}", level: "IP")
        html_response(200, result_page(confirmed: true, ip: ip))
      when "cancel"
        Mcpme::Logger.log("cancelled remote ip confirmation for #{ip}", level: "IP")
        html_response(200, result_page(confirmed: false, ip: ip))
      else
        [404, { "content-type" => "text/plain" }, ["Not Found"]]
      end
    end

    private

    def normalize(ip)
      RemoteIp.normalize(ip)
    end

    def html_response(status, body)
      [status, { "content-type" => "text/html; charset=utf-8", "cache-control" => "no-store" }, [body]]
    end

    def prompt_page(ip, signature, expires_at)
      query = "expires=#{CGI.escape(expires_at.to_s)}&signature=#{CGI.escape(signature)}"
      confirm_href = "/confirm-ip/#{CGI.escape(ip)}/confirm?#{query}"
      cancel_href = "/confirm-ip/#{CGI.escape(ip)}/cancel?#{query}"
      <<~HTML
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>mcpme — confirm IP</title>
          <style>
            body { font-family: ui-sans-serif, system-ui, sans-serif; max-width: 28rem; margin: 3rem auto; padding: 0 1rem; line-height: 1.5; }
            code { background: #f2f2f2; padding: 0.1em 0.35em; border-radius: 4px; }
            .actions { margin-top: 1.5rem; display: flex; gap: 1rem; align-items: center; }
            a.button { display: inline-block; background: #111; color: #fff; text-decoration: none; padding: 0.65rem 1.1rem; border-radius: 6px; }
            a.cancel { color: #555; }
          </style>
        </head>
        <body>
          <h1>mcpme</h1>
          <p>Allow remote IP <code>#{CGI.escapeHTML(ip)}</code> to run shell commands?</p>
          <div class="actions">
            <a class="button" href="#{CGI.escapeHTML(confirm_href)}">Confirm</a>
            <a class="cancel" href="#{CGI.escapeHTML(cancel_href)}">Cancel</a>
          </div>
        </body>
        </html>
      HTML
    end

    def result_page(confirmed:, ip:)
      message = if confirmed
                  "Thanks, ip confirmed"
                else
                  "Thanks, ip not confirmed"
                end
      redirect_url = CGI.escapeHTML(@config.base_url)
      <<~HTML
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>mcpme — #{CGI.escapeHTML(message)}</title>
          <style>
            body { font-family: ui-sans-serif, system-ui, sans-serif; max-width: 28rem; margin: 3rem auto; padding: 0 1rem; line-height: 1.5; }
            code { background: #f2f2f2; padding: 0.1em 0.35em; border-radius: 4px; }
          </style>
        </head>
        <body>
          <h1>mcpme</h1>
          <p>#{CGI.escapeHTML(message)} (<code>#{CGI.escapeHTML(ip)}</code>).</p>
          <p>You can close this window now.</p>
          <script>
            setTimeout(function () {
              window.location.href = #{JSON.generate(@config.base_url)};
            }, 15000);
          </script>
          <p><small>Redirecting to #{redirect_url} in 15 seconds…</small></p>
        </body>
        </html>
      HTML
    end

    def error_page(message)
      <<~HTML
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>mcpme — error</title>
        </head>
        <body>
          <h1>mcpme</h1>
          <p>#{CGI.escapeHTML(message)}</p>
        </body>
        </html>
      HTML
    end
  end
end
