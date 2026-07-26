# frozen_string_literal: true

module Mcpme
  module McpServer
    module_function

    def build
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
        return MCP::Tool::Response.new(
          [{ type: "text", text: "Error: command must not be empty" }],
          error: true
        )
      end

      output = `#{command} 2>&1`
      status = $?.exitstatus

      text = <<~TEXT
        exit_status: #{status}
        ---
        #{output}
      TEXT

      MCP::Tool::Response.new([{ type: "text", text: text }])
    rescue StandardError => e
      MCP::Tool::Response.new(
        [{ type: "text", text: "Shell execution failed: #{e.class}: #{e.message}" }],
        error: true
      )
    end
  end
end
