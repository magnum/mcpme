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

    # ChatGPT web requires these hints on every tool; Claude is lenient without them.
    RUN_SHELL_ANNOTATIONS = {
      read_only_hint: false,
      destructive_hint: false,
      idempotent_hint: false,
      open_world_hint: true
    }.freeze

    module_function

    def build(ip_gate: nil)
      @ip_gate = ip_gate
      server = MCP::Server.new(
        name: "mcpme",
        title: "mcpme — shell sul tuo PC",
        version: Mcpme::VERSION,
        instructions: "Questo MCP esegue comandi shell sul computer dell'utente (dove gira il server). " \
          "Usa il tool run_shell per lanciare un comando via backticks Ruby e ricevere stdout/stderr ed exit status. " \
          "Tratta ogni comando come azione locale reale sul PC dell'utente."
      )

      server.define_tool(
        name: "run_shell",
        title: "Esegui comando shell",
        description: "Esegue un comando shell sul PC dell'utente (macchina dove è in esecuzione mcpme), " \
          "tramite backticks Ruby (`comando`). Restituisce exit status e output combinato stdout/stderr.",
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
      output = `#{command} 2>&1`
      status = $?.exitstatus
      Mcpme::Logger.log("exit_status: #{status}", level: "CMD")
      Mcpme::Logger.log("output:\n#{output}", level: "CMD")

      text = <<~TEXT
        exit_status: #{status}
        ---
        #{output}
      TEXT

      structured_tool_result(
        text,
        data: { "exit_status" => status, "output" => output, "command" => command }
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
  end
end
