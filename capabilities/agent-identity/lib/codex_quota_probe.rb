# frozen_string_literal: true

require "json"
require "open3"
require "timeout"

class CodexQuotaProbeError < StandardError; end

# A bounded local JSONL client used only to decide whether an already registered
# owner identity has an explicit Codex rate-limit exhaustion signal. It never
# reads Codex files or returns account metadata.
class CodexQuotaProbe
  CLIENT_INFO = { "name" => "two-head-wu-agent-identity", "version" => "1" }.freeze

  def initialize(environment:, command: ["codex", "app-server", "--stdio"], timeout: 20, now: nil)
    @environment = environment
    @command = command
    @timeout = timeout
    @now = now || Time.now.to_i
    @next_id = 0
    @responses = {}
  end

  def call
    account = nil
    limits = nil
    Timeout.timeout(@timeout) do
      Open3.popen3(@environment, *@command) do |stdin, stdout, stderr, wait_thread|
        @stdin = stdin
        @stdout = stdout
        stderr_reader = Thread.new { stderr.read }
        begin
          request("initialize", {
                    "clientInfo" => CLIENT_INFO,
                    "capabilities" => { "experimentalApi" => true }
                  })
          notify("initialized", {})
          account = request("account/read", { "refreshToken" => false })["account"]
          limits = request("account/rateLimits/read", {})
        ensure
          @stdin.close unless @stdin.closed?
          unless wait_thread.join(2)
            Process.kill("TERM", wait_thread.pid)
            wait_thread.join(2)
          end
          stderr_reader.join(1)
        end
        raise CodexQuotaProbeError, "Codex app-server probe failed" unless wait_thread.value.success?
      end
    end
    return result("unknown", "not-logged-in") unless account.is_a?(Hash)

    quota = quota_analysis(limits)
    if quota.fetch(:exhausted) == true
      return result(
        "exhausted",
        "rate-limit-exhausted",
        blocking_reset_at: quota[:blocking_reset_at],
        next_reset_at: quota[:next_reset_at]
      )
    end
    if quota.fetch(:exhausted) == false
      return result("available", "rate-limit-available", next_reset_at: quota[:next_reset_at])
    end

    result("unknown", "rate-limit-unavailable")
  rescue Timeout::Error
    result("unknown", "probe-timeout")
  rescue CodexQuotaProbeError, JSON::ParserError, IOError, Errno::EPIPE, Errno::ENOENT
    result("unknown", "probe-failed")
  end

  private

  def result(status, reason, blocking_reset_at: nil, next_reset_at: nil)
    payload = { "status" => status, "reason" => reason }
    payload["blocking_reset_at"] = blocking_reset_at if blocking_reset_at
    payload["next_reset_at"] = next_reset_at if next_reset_at
    payload
  end

  def request(method, params)
    id = next_id
    write_message("id" => id, "method" => method, "params" => params)
    loop do
      return unwrap(@responses.delete(id)) if @responses.key?(id)
      dispatch(read_message)
    end
  end

  def notify(method, params)
    write_message("method" => method, "params" => params)
  end

  def next_id
    @next_id += 1
  end

  def write_message(value)
    @stdin.write(JSON.generate(value) + "\n")
    @stdin.flush
  end

  def read_message
    line = @stdout.gets
    raise CodexQuotaProbeError, "Codex app-server probe closed" unless line
    value = JSON.parse(line)
    raise CodexQuotaProbeError, "Codex app-server probe returned invalid data" unless value.is_a?(Hash)
    value
  end

  def dispatch(message)
    if message.key?("method") && message.key?("id")
      write_message("id" => message.fetch("id"), "error" => { "code" => -32_001, "message" => "unsupported during quota probe" })
    elsif message.key?("id")
      @responses[message.fetch("id")] = message
    end
  end

  def unwrap(response)
    raise CodexQuotaProbeError, "Codex app-server probe response was lost" unless response
    raise CodexQuotaProbeError, "Codex app-server probe request failed" if response["error"]
    response.fetch("result", {})
  end

  def quota_analysis(limits)
    return { exhausted: nil } unless limits.is_a?(Hash)
    raw = limits["rateLimitsByLimitId"]
    buckets = if raw.is_a?(Hash)
                raw.values
              elsif limits["rateLimits"].is_a?(Hash)
                [limits["rateLimits"]]
              else
                []
              end
    buckets.select! { |bucket| bucket.is_a?(Hash) }
    return { exhausted: nil } if buckets.empty?

    bucket = buckets.find { |item| item["limitId"].to_s == "codex" } || buckets.first
    windows = [bucket["primary"], bucket["secondary"]].select { |window| window.is_a?(Hash) }
    future_resets = windows.map { |window| reset_epoch(window) }.compact.select { |epoch| epoch > @now }
    next_reset_at = future_resets.min
    exhausted_windows = windows.select { |window| exhausted_window?(window) }
    explicitly_blocked = bucket["spendControlReached"] == true || !bucket["rateLimitReachedType"].to_s.empty?
    exhausted = explicitly_blocked || !exhausted_windows.empty?
    return { exhausted: nil } if windows.empty? && !explicitly_blocked

    reset_candidates = exhausted_windows.map { |window| reset_epoch(window) }.compact
    if reset_candidates.empty? && explicitly_blocked
      reset_candidates = windows.map { |window| reset_epoch(window) }.compact.select { |epoch| epoch > @now }
      blocking_reset_at = reset_candidates.min
    else
      # More than one exhausted window can block a request. Waiting for the
      # latest reset ensures both the short and long windows are available.
      blocking_reset_at = reset_candidates.max
    end
    { exhausted: exhausted, blocking_reset_at: blocking_reset_at, next_reset_at: next_reset_at }
  end

  def exhausted_window?(window)
    value = Float(window["usedPercent"])
    value.finite? && value >= 100.0
  rescue ArgumentError, TypeError
    false
  end

  def reset_epoch(window)
    value = Float(window["resetsAt"])
    return nil unless value.finite? && value.positive?

    value.to_i
  rescue ArgumentError, TypeError
    nil
  end
end
