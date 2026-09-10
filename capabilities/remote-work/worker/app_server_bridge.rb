#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require "securerandom"
require "thread"

require_relative "../lib/remote_work"

module RemoteWork
  # Small JSONL/JSON-RPC client for a local Codex app-server process. It never
  # exposes the app-server transport on the network; callers decide which
  # notifications and approval fields are safe to relay.
  class AppServerBridge
    CLIENT_INFO = { "name" => "two-head-wu-remote-worker", "version" => VERSION }.freeze

    def initialize(command:, environment: {}, notification_handler: nil, request_handler: nil, read_timeout: nil)
      @command = command
      @environment = environment
      @notification_handler = notification_handler || proc { |_method, _params| nil }
      @request_handler = request_handler || proc { |method, _params| raise Error, "unsupported app-server request: #{method}" }
      @read_timeout = read_timeout
      @next_id = 0
      @responses = {}
      @stderr_text = +""
    end

    def with_session
      Open3.popen3(@environment, *@command) do |stdin, stdout, stderr, wait_thread|
        @stdin = stdin
        @stdout = stdout
        stderr_reader = Thread.new do
          begin
            while (chunk = stderr.read(4096))
              @stderr_text << chunk
              @stderr_text = @stderr_text.byteslice(-16_384, 16_384) if @stderr_text.bytesize > 16_384
            end
          rescue IOError
            nil
          end
        end
        begin
          initialize_session
          yield self
        ensure
          @stdin.close unless @stdin.closed?
          unless wait_thread.join(3)
            Process.kill("TERM", wait_thread.pid)
            wait_thread.join(3)
          end
          stderr_reader.join(1)
          raise Error, "Codex app-server process failed" unless wait_thread.value.success?
        end
      end
    rescue Errno::ENOENT
      raise Error, "Codex app-server launcher is unavailable"
    end

    def request(method, params = {})
      id = next_id
      write_message("id" => id, "method" => method, "params" => params)
      loop do
        return unwrap_response(@responses.delete(id)) if @responses.key?(id)
        dispatch(read_message)
      end
    end

    def notify(method, params = {})
      write_message("method" => method, "params" => params)
    end

    def pump_until(interval: 1)
      loop do
        return if yield
        next unless IO.select([@stdout], nil, nil, interval)
        dispatch(read_message)
      end
    end

    private

    def initialize_session
      request("initialize", {
                "clientInfo" => CLIENT_INFO,
                "capabilities" => { "experimentalApi" => true }
              })
      notify("initialized", {})
    end

    def next_id
      @next_id += 1
    end

    def read_message
      if @read_timeout && !IO.select([@stdout], nil, nil, @read_timeout)
        raise Error, "Codex app-server response timed out"
      end
      line = @stdout.gets
      if line.nil?
        detail = @stderr_text.empty? ? "no diagnostic" : "diagnostic suppressed"
        raise Error, "Codex app-server closed unexpectedly (#{detail})"
      end
      value = JSON.parse(line)
      raise Error, "Codex app-server returned a non-object message" unless value.is_a?(Hash)
      value
    rescue JSON::ParserError
      raise Error, "Codex app-server returned invalid JSON"
    end

    def dispatch(message)
      if message.key?("method") && message.key?("id")
        handle_server_request(message)
      elsif message.key?("method")
        @notification_handler.call(message.fetch("method"), message.fetch("params", {}))
      elsif message.key?("id")
        @responses[message.fetch("id")] = message
      end
    end

    def handle_server_request(message)
      id = message.fetch("id")
      result = @request_handler.call(message.fetch("method"), message.fetch("params", {}))
      write_message("id" => id, "result" => result)
    rescue StandardError => error
      write_message("id" => id, "error" => { "code" => -32_001, "message" => safe_error(error) }) if id
    end

    def unwrap_response(response)
      raise Error, "Codex app-server response was lost" unless response
      if response["error"]
        code = response.dig("error", "code")
        raise Error, "Codex app-server request failed#{code ? " (#{code})" : ""}"
      end
      response.fetch("result", {})
    end

    def write_message(value)
      @stdin.write(JSON.generate(value) + "\n")
      @stdin.flush
    rescue IOError, Errno::EPIPE
      raise Error, "Codex app-server transport closed"
    end

    def safe_error(error)
      error.is_a?(Error) ? error.message[0, 500] : "remote interaction handler failed"
    end
  end
end
