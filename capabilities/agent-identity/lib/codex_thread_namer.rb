# frozen_string_literal: true

require "json"
require "open3"
require "timeout"

# Minimal stable app-server client for assigning a user-facing name to a Codex
# thread. It receives only a thread id and a user-chosen terminal-slot name.
class CodexThreadNamer
  CLIENT_INFO = { "name" => "two-head-wu-terminal-session", "version" => "1" }.freeze

  def initialize(environment:, command: ["codex", "app-server", "--stdio"], timeout: 8)
    @environment = environment
    @command = command
    @timeout = timeout
  end

  def call(thread_id:, name:)
    @next_id = 0
    @responses = {}
    success = false
    Timeout.timeout(@timeout) do
      Open3.popen3(@environment, *@command) do |stdin, stdout, stderr, wait_thread|
        @stdin = stdin
        @stdout = stdout
        stderr_reader = Thread.new { stderr.read }
        begin
          request("initialize", { "clientInfo" => CLIENT_INFO })
          notify("initialized", {})
          request("thread/name/set", { "threadId" => thread_id, "name" => name })
          success = true
        ensure
          @stdin.close unless @stdin.closed?
          stop_process(wait_thread)
          unless stderr_reader.join(1)
            stderr_reader.kill
            stderr_reader.join
          end
        end
        success &&= !wait_thread.alive? && wait_thread.value.success?
      end
    end
    success
  rescue Timeout::Error, JSON::ParserError, IOError, Errno::EPIPE, Errno::ENOENT
    false
  end

  private

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
    raise IOError, "Codex app-server closed before naming the thread" unless line

    value = JSON.parse(line)
    raise IOError, "Codex app-server returned invalid data" unless value.is_a?(Hash)

    value
  end

  def dispatch(message)
    if message.key?("method") && message.key?("id")
      write_message("id" => message.fetch("id"), "error" => { "code" => -32_001, "message" => "unsupported while naming a thread" })
    elsif message.key?("id")
      @responses[message.fetch("id")] = message
    end
  end

  def unwrap(response)
    raise IOError, "Codex app-server response was lost" unless response
    raise IOError, "Codex app-server rejected the thread name" if response["error"]

    response.fetch("result", {})
  end

  def stop_process(wait_thread)
    return if wait_thread.join(2)

    Process.kill("TERM", wait_thread.pid)
    return if wait_thread.join(1)

    Process.kill("KILL", wait_thread.pid)
    wait_thread.join(1)
  rescue Errno::ESRCH
    wait_thread.join(1)
  end
end
