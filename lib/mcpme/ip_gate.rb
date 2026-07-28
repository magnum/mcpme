# frozen_string_literal: true

module Mcpme
  # Blocks shell commands from unknown remote IPs until confirmed via Pushover.
  class IpGate
    NOTIFY_COOLDOWN = 120

    def initialize(config:, allowlist:, confirm:, pushover:)
      @config = config
      @allowlist = allowlist
      @confirm = confirm
      @pushover = pushover
      @mutex = Mutex.new
      @last_notify_at = {}
    end

    # Returns nil if the command may proceed, otherwise an error message for the tool.
    def deny_reason_for(ip)
      return nil unless @config.confirm_new_remote_ips?
      return "Remote IP could not be determined" if ip.nil? || ip.empty?
      return nil if RemoteIp.local?(ip)
      return nil if @allowlist.allowed?(ip)

      notify!(ip)
      if @pushover.configured?
        "Remote IP #{ip} is not on the allowlist. A Pushover confirmation was sent — " \
          "open the link in the notification to allow this IP, then retry the command."
      else
        "Remote IP #{ip} is not on the allowlist. Configure PUSHOVER_TOKEN / PUSHOVER_USER " \
          "to receive a confirmation link, or add the IP to #{@config.allowed_remote_ips_path}."
      end
    end

    private

    def notify!(ip)
      unless @pushover.configured?
        Mcpme::Logger.log("cannot notify for #{ip}: Pushover not configured", level: "ERROR")
        return
      end

      unless should_notify?(ip)
        Mcpme::Logger.log("skipping duplicate Pushover for #{ip} (cooldown)", level: "IP")
        return
      end

      url = @confirm.confirm_url(ip)
      @pushover.send_message(
        title: "mcpme — confirm ip",
        message: url,
        url: url,
        url_title: "Confirm IP"
      )
      Mcpme::Logger.log("sent Pushover confirm for #{ip}: #{url}", level: "IP")
    rescue StandardError => e
      Mcpme::Logger.log("Pushover failed for #{ip}: #{e.class}: #{e.message}", level: "ERROR")
    end

    def should_notify?(ip)
      @mutex.synchronize do
        last = @last_notify_at[ip]
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return false if last && (now - last) < NOTIFY_COOLDOWN

        @last_notify_at[ip] = now
        true
      end
    end
  end
end
