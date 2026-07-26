# frozen_string_literal: true

module Mcpme
  module TunnelHelpers
    LOCAL_HOSTS = %w[127.0.0.1 localhost ::1].freeze

    module_function

    def public_hostname?(host)
      host && !LOCAL_HOSTS.include?(host)
    end
  end
end
