# frozen_string_literal: true

require "dotenv/load"
require "mcp"
require "rack"
require "json"
require "securerandom"
require "digest"
require "cgi"
require "uri"
require "time"
require "base64"

require_relative "mcpme/version"
require_relative "mcpme/logger"
require_relative "mcpme/config"
require_relative "mcpme/tunnel_helpers"
require_relative "mcpme/remote_ip"
require_relative "mcpme/ip_allowlist"
require_relative "mcpme/ip_confirm"
require_relative "mcpme/pushover"
require_relative "mcpme/ip_gate"
require_relative "mcpme/oauth/store"
require_relative "mcpme/oauth/server"
require_relative "mcpme/auth_middleware"
require_relative "mcpme/access_log_middleware"
require_relative "mcpme/mcp_server"
require_relative "mcpme/app"

module Mcpme
end
