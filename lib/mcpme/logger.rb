# frozen_string_literal: true

require "fileutils"

module Mcpme
  # Single entry point for every application log line.
  # Both the log file and `./mcpme.sh logs` show lines produced by Logger.log.
  class Logger
    class << self
      def log_path
        @log_path ||= File.expand_path("log/mcpme.log", Dir.pwd)
      end

      attr_writer :log_path

      # Formats and writes one log line. This is the only method that creates log lines.
      def log(message, level: "INFO")
        formatted = line(level, message)
        write(formatted)
        formatted
      end

      def line(level, message)
        ts = Time.now.strftime("%Y-%m-%d %H:%M:%S %z")
        "[#{ts}] #{level} #{message}"
      end

      def write(formatted_line)
        FileUtils.mkdir_p(File.dirname(log_path))
        File.open(log_path, "a") do |file|
          file.puts(formatted_line)
          file.flush
        end
        $stdout.puts(formatted_line)
        $stdout.flush
      rescue StandardError => e
        $stderr.puts("mcpme logger error: #{e.class}: #{e.message}")
      end
    end
  end
end
