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
      Mcpme::Logger.log(
        %(#{request.ip} "#{request.request_method} #{request.fullpath} #{request.get_header("SERVER_PROTOCOL")}" #{status} #{length} #{format("%.4f", duration)}s),
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
  end
end
