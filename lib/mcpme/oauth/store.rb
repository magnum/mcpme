# frozen_string_literal: true

require "json"
require "fileutils"
require "time"

module Mcpme
  module OAuth
    # Persists clients, auth codes, and tokens to disk so restarts keep sessions.
    class Store
      def initialize(path: File.expand_path("data/oauth_store.json", Dir.pwd))
        @path = path
        @mutex = Mutex.new
        @clients = {}
        @auth_codes = {}
        @access_tokens = {}
        @refresh_tokens = {}
        load_from_disk!
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

        @mutex.synchronize do
          @clients[client_id] = record
          persist_unlocked!
        end
        record
      end

      def find_client(client_id)
        @mutex.synchronize { deep_dup(@clients[client_id]) }
      end

      def save_auth_code(code, payload)
        @mutex.synchronize do
          @auth_codes[code] = payload.merge(created_at: Time.now.utc)
          persist_unlocked!
        end
      end

      def consume_auth_code(code)
        @mutex.synchronize do
          record = @auth_codes.delete(code)
          persist_unlocked! if record
          record
        end
      end

      def save_access_token(token, payload)
        @mutex.synchronize do
          @access_tokens[token] = payload.merge(created_at: Time.now.utc)
          persist_unlocked!
        end
      end

      def find_access_token(token)
        @mutex.synchronize do
          record = @access_tokens[token]
          next nil unless record
          next expire_access_token!(token) if expired?(record)

          deep_dup(record)
        end
      end

      def save_refresh_token(token, payload)
        @mutex.synchronize do
          @refresh_tokens[token] = payload.merge(created_at: Time.now.utc)
          persist_unlocked!
        end
      end

      def consume_refresh_token(token)
        @mutex.synchronize do
          record = @refresh_tokens.delete(token)
          persist_unlocked! if record
          record
        end
      end

      private

      def expired?(record)
        expires_at = record[:expires_at]
        expires_at && Time.now.utc >= expires_at
      end

      def expire_access_token!(token)
        @access_tokens.delete(token)
        persist_unlocked!
        nil
      end

      def load_from_disk!
        return unless File.file?(@path)

        data = JSON.parse(File.read(@path))
        @clients = deserialize_map(data["clients"])
        @auth_codes = deserialize_map(data["auth_codes"])
        @access_tokens = deserialize_map(data["access_tokens"])
        @refresh_tokens = deserialize_map(data["refresh_tokens"])
        purge_expired_unlocked!
        FileMode.restrict!(@path)
      rescue StandardError => e
        warn "mcpme oauth store load failed: #{e.class}: #{e.message}"
      end

      def deserialize_map(raw)
        return {} unless raw.is_a?(Hash)

        raw.each_with_object({}) do |(key, value), hash|
          hash[key.to_s] = deserialize_record(value)
        end
      end

      def deserialize_record(value)
        return value unless value.is_a?(Hash)

        value.each_with_object({}) do |(key, entry), hash|
          sym = key.to_sym
          hash[sym] =
            if entry.is_a?(String) && key.to_s.end_with?("_at")
              Time.parse(entry).utc
            else
              entry
            end
        rescue ArgumentError, TypeError
          hash[sym] = entry
        end
      end

      def purge_expired_unlocked!
        @auth_codes.delete_if { |_k, v| expired?(v) }
        @access_tokens.delete_if { |_k, v| expired?(v) }
        @refresh_tokens.delete_if { |_k, v| expired?(v) }
      end

      def persist_unlocked!
        FileUtils.mkdir_p(File.dirname(@path))
        payload = {
          "clients" => serialize(@clients),
          "auth_codes" => serialize(@auth_codes),
          "access_tokens" => serialize(@access_tokens),
          "refresh_tokens" => serialize(@refresh_tokens)
        }
        tmp = "#{@path}.tmp"
        File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
          file.write(JSON.pretty_generate(payload))
        end
        File.rename(tmp, @path)
        FileMode.restrict!(@path)
      end

      def serialize(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, entry), hash|
            hash[key.to_s] = serialize(entry)
          end
        when Array
          value.map { |entry| serialize(entry) }
        when Time
          value.utc.iso8601
        else
          value
        end
      end

      def deep_dup(value)
        case value
        when Hash
          value.transform_values { |entry| deep_dup(entry) }
        when Array
          value.map { |entry| deep_dup(entry) }
        else
          value
        end
      end
    end
  end
end
