# frozen_string_literal: true

require "json"
require "open3"
require "timeout"

class CodexTurnProbeError < StandardError; end

# A bounded local JSONL client for conditional continuation. Codex returns the
# thread payload, but this probe retains and exposes only runtime status plus the
# latest turn UUID/status; item and message content are never returned or stored.
class CodexTurnProbe
  CLIENT_INFO = { "name" => "two-head-wu-agent-identity", "version" => "1" }.freeze
  TURN_STATUSES = %w[completed interrupted failed inProgress].freeze

  def initialize(environment:, command: ["codex", "app-server", "--stdio"], timeout: 20)
    @environment = environment
    @command = command
    @timeout = timeout
    @next_id = 0
    @responses = {}
  end

  def call(thread_id:)
    thread = nil
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
          thread = request("thread/read", {
                             "threadId" => thread_id,
                             "includeTurns" => true
                           })["thread"]
        ensure
          @stdin.close unless @stdin.closed?
          unless wait_thread.join(2)
            Process.kill("TERM", wait_thread.pid)
            wait_thread.join(2)
          end
          stderr_reader.join(1)
        end
        raise CodexTurnProbeError, "Codex app-server probe failed" unless wait_thread.value.success?
      end
    end
    return result("unknown", "thread-unavailable") unless thread.is_a?(Hash)

    turns = thread["turns"]
    return result("unknown", "turns-unavailable") unless turns.is_a?(Array)

    latest = turns.last
    return result("ok", "no-persisted-turn", thread_status: thread_status(thread)) unless latest
    return result("unknown", "turn-metadata-invalid") unless latest.is_a?(Hash)

    turn_id = latest["id"].to_s.downcase
    turn_status = latest["status"].to_s
    unless uuid?(turn_id) && TURN_STATUSES.include?(turn_status)
      return result("unknown", "turn-metadata-invalid")
    end

    result(
      "ok",
      "turn-metadata-available",
      thread_status: thread_status(thread),
      latest_turn_id: turn_id,
      latest_turn_status: turn_status
    )
  rescue Timeout::Error
    result("unknown", "probe-timeout")
  rescue CodexTurnProbeError, JSON::ParserError, IOError, Errno::EPIPE, Errno::ENOENT
    result("unknown", "probe-failed")
  end

  private

  def result(status, reason, thread_status: nil, latest_turn_id: nil, latest_turn_status: nil)
    payload = { "status" => status, "reason" => reason }
    payload["thread_status"] = thread_status if thread_status
    payload["latest_turn_id"] = latest_turn_id if latest_turn_id
    payload["latest_turn_status"] = latest_turn_status if latest_turn_status
    payload
  end

  def thread_status(thread)
    status = thread["status"]
    status.is_a?(Hash) ? status["type"].to_s : nil
  end

  def uuid?(value)
    /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i.match?(value)
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
    raise CodexTurnProbeError, "Codex app-server probe closed" unless line

    value = JSON.parse(line)
    raise CodexTurnProbeError, "Codex app-server probe returned invalid data" unless value.is_a?(Hash)

    value
  end

  def dispatch(message)
    if message.key?("method") && message.key?("id")
      write_message("id" => message.fetch("id"), "error" => { "code" => -32_001, "message" => "unsupported during turn probe" })
    elsif message.key?("id")
      @responses[message.fetch("id")] = message
    end
  end

  def unwrap(response)
    raise CodexTurnProbeError, "Codex app-server probe response was lost" unless response
    raise CodexTurnProbeError, "Codex app-server probe request failed" if response["error"]

    response.fetch("result", {})
  end
end
