# frozen_string_literal: true

module Mcpme
  module McpServer
    OUTPUT_SCHEMA = {
      type: "object",
      properties: {
        text: { type: "string", description: "Human-readable tool output." },
        data: { description: "Structured JSON payload when the tool returns data." }
      },
      required: ["text"],
      additionalProperties: false
    }.freeze

    # ChatGPT uses these hints to decide whether to ask before running the tool.
    # The shell can delete files and change the machine, so it is destructive.
    RUN_SHELL_ANNOTATIONS = {
      read_only_hint: false,
      destructive_hint: true,
      idempotent_hint: false,
      open_world_hint: true
    }.freeze

    module_function

    def build(ip_gate: nil, command_timeout: 60, command_max_output_bytes: 1_048_576)
      @ip_gate = ip_gate
      @command_timeout = command_timeout
      @command_max_output_bytes = command_max_output_bytes
      server = MCP::Server.new(
        name: "mcpme",
        title: "mcpme — shell sul tuo PC",
        version: Mcpme::VERSION,
        instructions: "Questo MCP esegue comandi shell sul computer dell'utente (dove gira il server). " \
          "Usa il tool run_shell per lanciare un comando e ricevere stdout/stderr ed exit status. " \
          "Tratta ogni comando come azione locale reale sul PC dell'utente."
      )

      server.define_tool(
        name: "run_shell",
        title: "Esegui comando shell",
        description: "Esegue un comando shell sul PC dell'utente (macchina dove è in esecuzione mcpme). " \
          "Restituisce exit status e output combinato stdout/stderr.",
        input_schema: {
          type: "object",
          properties: {
            command: {
              type: "string",
              description: "Comando shell da eseguire sul PC dell'utente"
            }
          },
          required: ["command"],
          additionalProperties: false
        },
        output_schema: OUTPUT_SCHEMA,
        annotations: RUN_SHELL_ANNOTATIONS
      ) do |command:, server_context:|
        Mcpme::McpServer.execute_command(command)
      end

      ModernProtocol.install!(server)
    end

    def execute_command(command)
      command = command.to_s
      if command.strip.empty?
        Mcpme::Logger.log("command rejected: empty", level: "CMD")
        return tool_error("Error: command must not be empty")
      end

      if (reason = gate_ensure_allowed)
        Mcpme::Logger.log("command blocked: #{reason}", level: "IP")
        return tool_error(reason)
      end

      Mcpme::Logger.log("command: #{command}", level: "CMD")
      output, status, timed_out, truncated = capture_shell(command)
      if timed_out
        Mcpme::Logger.log("command timed out after #{command_timeout}s", level: "CMD")
        return tool_error("Command timed out after #{command_timeout}s\n---\n#{output}")
      end
      if truncated
        Mcpme::Logger.log("command output exceeded #{command_max_output_bytes} bytes", level: "CMD")
        return tool_error("Command output exceeded #{command_max_output_bytes} bytes and was stopped\n---\n#{output}")
      end

      exit_status = exit_label(status)
      Mcpme::Logger.log("exit_status: #{exit_status}", level: "CMD")
      Mcpme::Logger.log("output:\n#{output}", level: "CMD")

      text = <<~TEXT
        exit_status: #{exit_status}
        ---
        #{output}
      TEXT

      structured_tool_result(
        text,
        data: { "exit_status" => exit_status, "output" => output, "command" => command }
      )
    rescue StandardError => e
      Mcpme::Logger.log("command failed: #{e.class}: #{e.message}", level: "ERROR")
      tool_error("Shell execution failed: #{e.class}: #{e.message}")
    end

    def structured_tool_result(text, data:)
      MCP::Tool::Response.new(
        [{ type: "text", text: text }],
        structured_content: { "text" => text, "data" => data }
      )
    end

    def tool_error(message)
      MCP::Tool::Response.new(
        [{ type: "text", text: message }],
        error: true,
        structured_content: { "text" => message, "data" => nil }
      )
    end

    def gate_ensure_allowed
      return nil unless @ip_gate

      @ip_gate.ensure_allowed!(RemoteIp.current)
    end

    def command_timeout
      @command_timeout || 60
    end

    def command_max_output_bytes
      @command_max_output_bytes || 1_048_576
    end

    def capture_shell(command)
      reader, writer = IO.pipe
      pid = nil
      status = nil
      output = +"".b
      timed_out = false
      truncated = false
      limit = command_max_output_bytes

      begin
        pid = Process.spawn(command, in: :close, out: writer, err: writer, pgroup: true)
        writer.close
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + command_timeout

        loop do
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          if remaining <= 0
            timed_out = true
            break
          end

          readable, = IO.select([reader], nil, nil, remaining)
          unless readable
            timed_out = true
            break
          end

          chunk = reader.read_nonblock(16_384, exception: false)
          case chunk
          when nil
            break
          when :wait_readable
            next
          else
            room = limit - output.bytesize
            if chunk.bytesize > room
              output << chunk.byteslice(0, room)
              truncated = true
              break
            end
            output << chunk
          end
        end
      ensure
        writer.close unless writer.closed?
        reader.close unless reader.closed?
        if pid
          kill_group(pid) if timed_out || truncated
          _, status = Process.wait2(pid)
        end
      end

      [output.force_encoding(Encoding::UTF_8).scrub, status, timed_out, truncated]
    end

    def kill_group(pid)
      Process.kill("TERM", -pid)
      10.times do
        sleep 0.05
        break unless alive?(pid)
      end
      Process.kill("KILL", -pid) if alive?(pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end

    def alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    end

    def exit_label(status)
      return nil unless status
      return "signal #{status.termsig}" if status.signaled?

      status.exitstatus
    end
  end
end
