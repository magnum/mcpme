# frozen_string_literal: true

module Mcpme
  class Config
    DEFAULT_CERT = "certs/localhost+2.pem"
    DEFAULT_KEY = "certs/localhost+2-key.pem"
    DEFAULT_ALLOWED_IPS = "data/allowed_remote_ips.txt"

    attr_reader :oauth_user, :oauth_password, :base_url, :host, :port,
                :ssl_cert_path, :ssl_key_path, :oauth_token_ttl_days,
                :secret_key, :pushover_token, :pushover_user, :pushover_device,
                :allowed_remote_ips_path, :confirm_wait_seconds

    def self.load
      base_url = ENV.fetch("MCP_BASE_URL", "http://127.0.0.1:9292").chomp("/")
      host = ENV.fetch("HOST", URI(base_url).host || "127.0.0.1")
      port = Integer(ENV.fetch("PORT", URI(base_url).port&.to_s || "9292"))

      cert = ENV["SSL_CERT_PATH"]
      key = ENV["SSL_KEY_PATH"]
      cert = DEFAULT_CERT if cert.nil? || cert.empty?
      key = DEFAULT_KEY if key.nil? || key.empty?

      ips_path = ENV["ALLOWED_REMOTE_IPS_PATH"]
      ips_path = DEFAULT_ALLOWED_IPS if ips_path.nil? || ips_path.empty?

      new(
        oauth_user: ENV.fetch("OAUTH_USER"),
        oauth_password: ENV.fetch("OAUTH_PASSWORD"),
        base_url: base_url,
        host: host,
        port: port,
        ssl_cert_path: cert,
        ssl_key_path: key,
        oauth_token_ttl_days: Float(ENV.fetch("OAUTH_TOKEN_TTL_DAYS", "7")),
        confirm_remote_ips: env_boolean(ENV["CONFIRM_REMOTE_IPS"]),
        secret_key: ENV.fetch("SECRET_KEY", ""),
        pushover_token: ENV.fetch("PUSHOVER_TOKEN", ""),
        pushover_user: ENV.fetch("PUSHOVER_USER", ""),
        pushover_device: ENV.fetch("PUSHOVER_DEVICE", ""),
        allowed_remote_ips_path: ips_path,
        confirm_wait_seconds: Integer(ENV.fetch("CONFIRM_WAIT_SECONDS", "15"))
      )
    end

    def self.env_boolean(value, default: false)
      return default if value.nil? || value.to_s.strip.empty?

      case value.to_s.strip.downcase
      when "1", "true", "yes", "on"
        true
      when "0", "false", "no", "off"
        false
      else
        default
      end
    end

    def initialize(
      oauth_user:,
      oauth_password:,
      base_url:,
      host:,
      port:,
      ssl_cert_path:,
      ssl_key_path:,
      oauth_token_ttl_days:,
      confirm_remote_ips:,
      secret_key:,
      pushover_token:,
      pushover_user:,
      pushover_device:,
      allowed_remote_ips_path:,
      confirm_wait_seconds:
    )
      @oauth_user = oauth_user
      @oauth_password = oauth_password
      @base_url = base_url
      @host = host
      @port = port
      @ssl_cert_path = ssl_cert_path
      @ssl_key_path = ssl_key_path
      @oauth_token_ttl_days = oauth_token_ttl_days
      @confirm_remote_ips = confirm_remote_ips
      @secret_key = secret_key
      @pushover_token = pushover_token
      @pushover_user = pushover_user
      @pushover_device = pushover_device
      @allowed_remote_ips_path = allowed_remote_ips_path
      @confirm_wait_seconds = confirm_wait_seconds
    end

    def confirm_remote_ips?
      @confirm_remote_ips
    end

    def mcp_resource_url
      "#{base_url}/mcp"
    end

    def issuer
      base_url
    end

    def https?
      base_url.start_with?("https://")
    end

    def ssl_enabled?
      return false if ENV["SSL_ENABLED"] == "0"
      return false unless File.file?(ssl_cert_path) && File.file?(ssl_key_path)

      true
    end

    def oauth_token_ttl_seconds
      (oauth_token_ttl_days * 24 * 60 * 60).to_i
    end

    def credentials_match?(username, password)
      secure_compare(oauth_user, username.to_s) && secure_compare(oauth_password, password.to_s)
    end

    private

    def secure_compare(left, right)
      return false unless left.bytesize == right.bytesize

      Rack::Utils.secure_compare(left, right)
    end
  end
end
