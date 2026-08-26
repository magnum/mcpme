# frozen_string_literal: true

module Mcpme
  # HTTP access logger that uses Mcpme::Logger for every line.
  class AccessLogMiddleware
    def initialize(app)
      @app = app
    end

    def call(env)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      status, headers, body = @app.call(env)
      duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      request = Rack::Request.new(env)
      length = headers["Content-Length"] || headers["content-length"] || "-"
      detail = mcp_detail(env, status, body)
      Mcpme::Logger.log(
        %(#{request.ip} "#{request.request_method} #{request.fullpath} #{request.get_header("SERVER_PROTOCOL")}" #{status} #{length} #{format("%.4f", duration)}s#{detail}),
        level: "HTTP"
      )

      [status, headers, body]
    rescue StandardError => e
      duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      request = Rack::Request.new(env)
      Mcpme::Logger.log(
        %(#{request.ip} "#{request.request_method} #{request.fullpath}" error=#{e.class}: #{e.message} #{format("%.4f", duration)}s),
        level: "HTTP"
      )
      raise
    end

    private

    def mcp_detail(env, status, body)
      return "" unless status.to_i >= 400

      path = env["PATH_INFO"].to_s
      return "" unless path == "/mcp" || path.start_with?("/mcp/") || path == "/" || path.empty?

      bits = []
      version = env["HTTP_MCP_PROTOCOL_VERSION"]
      bits << "proto=#{version}" if version && !version.empty?
      bits << "session=#{env["HTTP_MCP_SESSION_ID"]}" if env["HTTP_MCP_SESSION_ID"]

      raw = env["mcpme.request_body"].to_s
      unless raw.empty?
        parsed = begin
          JSON.parse(raw)
        rescue StandardError
          nil
        end
        bits << "method=#{parsed["method"]}" if parsed.is_a?(Hash) && parsed["method"]
      end

      snippet = body_snippet(body)
      bits << "err=#{snippet}" if snippet

      bits.empty? ? "" : " #{bits.join(" ")}"
    end

    def body_snippet(body)
      text = +""
      body.each { |chunk| text << chunk.to_s }
      return nil if text.empty?

      text = text.tr("\n", " ")
      text.length > 180 ? "#{text[0, 180]}…" : text
    rescue StandardError
      nil
    end
  end
end
