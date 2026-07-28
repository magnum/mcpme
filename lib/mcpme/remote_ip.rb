# frozen_string_literal: true

require "ipaddr"

module Mcpme
  module RemoteIp
    LOCAL_CIDRS = [
      "127.0.0.0/8",
      "::1/128",
      "10.0.0.0/8",
      "172.16.0.0/12",
      "192.168.0.0/16",
      "fc00::/7",
      "fe80::/10"
    ].map { |cidr| IPAddr.new(cidr) }.freeze

    module_function

    # Prefer Cloudflare's connecting IP, then X-Forwarded-For, then Rack.
    def from_request(request)
      cf = request.get_header("HTTP_CF_CONNECTING_IP").to_s.strip
      return normalize(cf) if valid?(cf)

      xff = request.get_header("HTTP_X_FORWARDED_FOR").to_s
      unless xff.empty?
        first = xff.split(",").first.to_s.strip
        return normalize(first) if valid?(first)
      end

      normalize(request.ip.to_s)
    end

    def current
      Thread.current[:mcpme_remote_ip]
    end

    def current=(value)
      Thread.current[:mcpme_remote_ip] = value
    end

    def local?(ip)
      addr = IPAddr.new(ip.to_s)
      LOCAL_CIDRS.any? { |cidr| cidr.include?(addr) }
    rescue IPAddr::Error
      false
    end

    def valid?(ip)
      return false if ip.nil? || ip.strip.empty?

      IPAddr.new(ip.strip)
      true
    rescue IPAddr::Error
      false
    end

    def normalize(ip)
      IPAddr.new(ip.to_s.strip).to_s
    rescue IPAddr::Error
      ip.to_s.strip
    end
  end
end
