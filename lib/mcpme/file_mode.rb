# frozen_string_literal: true

module Mcpme
  # Keeps secret files readable only by the account that runs the server.
  module FileMode
    module_function

    def restrict!(path)
      return unless path && File.exist?(path)

      File.chmod(0o600, path)
    rescue SystemCallError => e
      warn "mcpme: could not restrict #{path}: #{e.message}"
    end
  end
end
