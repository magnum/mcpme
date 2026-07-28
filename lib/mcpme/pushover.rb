# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module Mcpme
  class Pushover
    ENDPOINT = URI("https://api.pushover.net/1/messages.json")

    def initialize(token:, user:, device: nil)
      @token = token.to_s
      @user = user.to_s
      @device = device.to_s
    end

    def configured?
      !@token.empty? && !@user.empty?
    end

    def send_message(title:, message:, url: nil, url_title: nil)
      raise "Pushover is not configured" unless configured?

      form = {
        "token" => @token,
        "user" => @user,
        "title" => title,
        "message" => message
      }
      form["device"] = @device unless @device.empty?
      form["url"] = url if url
      form["url_title"] = url_title if url_title

      response = Net::HTTP.post_form(ENDPOINT, form)
      body = response.body.to_s
      unless response.is_a?(Net::HTTPSuccess)
        raise "Pushover HTTP #{response.code}: #{body}"
      end

      parsed = JSON.parse(body)
      raise "Pushover status=#{parsed["status"]}: #{body}" unless parsed["status"] == 1

      parsed
    end
  end
end
