# frozen_string_literal: true

module Mcpme
  module McpServer
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
        }
      ) do |command:, server_context:|
        Mcpme::McpServer.execute_command(command)
      end

      server
    end

    def execute_command(command)
      command = command.to_s
      if command.strip.empty?
        Mcpme::Logger.log("command rejected: empty", level: "CMD")
        return MCP::Tool::Response.new(
          [{ type: "text", text: "Error: command must not be empty" }],
          error: true
        )
      end

      if (reason = gate_ensure_allowed)
        Mcpme::Logger.log("command blocked: #{reason}", level: "IP")
        return MCP::Tool::Response.new(
          [{ type: "text", text: reason }],
          error: true
        )
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

      MCP::Tool::Response.new([{ type: "text", text: text }])
    rescue StandardError => e
      Mcpme::Logger.log("command failed: #{e.class}: #{e.message}", level: "ERROR")
      MCP::Tool::Response.new(
        [{ type: "text", text: "Shell execution failed: #{e.class}: #{e.message}" }],
        error: true
      )
    end

    def gate_ensure_allowed
      return nil unless @ip_gate

      @ip_gate.ensure_allowed!(RemoteIp.current)
    end
  end
end
