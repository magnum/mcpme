# frozen_string_literal: true

module Mcpme
  # Blocks shell commands from unknown remote IPs until confirmed via Pushover.
  class IpGate
    NOTIFY_COOLDOWN = 120
    POLL_INTERVAL = 0.25

    def initialize(config:, allowlist:, activity:, confirm:, pushover:)
      @config = config
      @allowlist = allowlist
      @activity = activity
      @confirm = confirm
      @pushover = pushover
      @mutex = Mutex.new
      @last_notify_at = {}
    end

    # Returns nil if the command may proceed, otherwise a short error for the tool.
    # Details are logged via Mcpme::Logger.
    def ensure_allowed!(ip)
      return nil unless @config.confirm_remote_ips?
      return "Remote IP could not be determined" if ip.nil? || ip.empty?
      return nil if RemoteIp.local?(ip)
      if @allowlist.allowed?(ip) && @activity.fresh?(ip)
        @activity.touch!(ip)
        return nil
      end

      idle = @allowlist.allowed?(ip)
      unless @pushover.configured?
        Mcpme::Logger.log(
          "remote IP #{ip} #{idle ? "idle" : "not on allowlist"} — Pushover not configured (#{@config.allowed_remote_ips_path})",
          level: "IP"
        )
        return "Remote IP not allowed."
      end

      mark = Time.now.utc
      notify!(ip)
      wait = @config.confirm_wait_seconds
      reason = idle ? "idle for #{@config.confirm_idle_minutes}m" : "not on allowlist"
      Mcpme::Logger.log(
        "remote IP #{ip} #{reason} — Pushover sent, waiting up to #{wait}s for confirmation",
        level: "IP"
      )

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + wait
      while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        if @allowlist.allowed?(ip) && @activity.touched_after?(ip, mark)
          @activity.touch!(ip)
          Mcpme::Logger.log("remote IP #{ip} confirmed during wait — proceeding", level: "IP")
          return nil
        end

        sleep(POLL_INTERVAL)
      end

      Mcpme::Logger.log("remote IP #{ip} not confirmed within #{wait}s — command blocked", level: "IP")
      "Remote IP not confirmed in time."
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
      Mcpme::Logger.log("sent Pushover confirm for #{ip}", level: "IP")
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
