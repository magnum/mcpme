# frozen_string_literal: true

require_relative "lib/mcpme"

config = Mcpme::Config.load
run Mcpme::App.build(config: config)
