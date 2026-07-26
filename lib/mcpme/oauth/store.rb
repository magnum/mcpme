# frozen_string_literal: true

module Mcpme
  module OAuth
    # In-memory store for clients, auth codes, and access tokens.
    class Store
      def initialize
        @mutex = Mutex.new
        @clients = {}
        @auth_codes = {}
        @access_tokens = {}
        @refresh_tokens = {}
      end

      def register_client(client_metadata)
        client_id = SecureRandom.uuid
        grant_types = Array(client_metadata["grant_types"])
        grant_types = %w[authorization_code refresh_token] if grant_types.empty?
        response_types = Array(client_metadata["response_types"])
        response_types = %w[code] if response_types.empty?

        record = {
          client_id: client_id,
          client_secret: nil,
          redirect_uris: Array(client_metadata["redirect_uris"]),
          grant_types: grant_types,
          response_types: response_types,
          token_endpoint_auth_method: client_metadata["token_endpoint_auth_method"] || "none",
          client_name: client_metadata["client_name"],
          created_at: Time.now.utc
        }

        @mutex.synchronize { @clients[client_id] = record }
        record
      end

      def find_client(client_id)
        @mutex.synchronize { @clients[client_id]&.dup }
      end

      def save_auth_code(code, payload)
        @mutex.synchronize { @auth_codes[code] = payload.merge(created_at: Time.now.utc) }
      end

      def consume_auth_code(code)
        @mutex.synchronize { @auth_codes.delete(code) }
      end

      def save_access_token(token, payload)
        @mutex.synchronize { @access_tokens[token] = payload.merge(created_at: Time.now.utc) }
      end

      def find_access_token(token)
        @mutex.synchronize do
          record = @access_tokens[token]
          next nil unless record
          next expire_access_token!(token) if expired?(record)

          record.dup
        end
      end

      def save_refresh_token(token, payload)
        @mutex.synchronize { @refresh_tokens[token] = payload.merge(created_at: Time.now.utc) }
      end

      def consume_refresh_token(token)
        @mutex.synchronize { @refresh_tokens.delete(token) }
      end

      private

      def expired?(record)
        expires_at = record[:expires_at]
        expires_at && Time.now.utc >= expires_at
      end

      def expire_access_token!(token)
        @access_tokens.delete(token)
        nil
      end
    end
  end
end
