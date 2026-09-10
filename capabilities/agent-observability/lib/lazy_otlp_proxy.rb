# frozen_string_literal: true

require "fiddle"
require "net/http"
require "socket"
require "thread"

require_relative "agent_observability"

module TwoHeadWu
  class LazyOtlpProxy
    MAX_BODY_BYTES = 8 * 1024 * 1024
    MAX_QUEUED_BYTES = 32 * 1024 * 1024
    MAX_HEADER_BYTES = 32 * 1024
    REQUEST_WORKERS = 16
    MAX_PENDING_REQUESTS = 64
    REQUEST_READ_TIMEOUT_SECONDS = 5

    def initialize(observability:, environment: ENV,
                   provider_ready_timeout_seconds: nil, provider_poll_seconds: 1,
                   request_read_timeout_seconds: REQUEST_READ_TIMEOUT_SECONDS,
                   backend_port: AgentObservability::BACKEND_PORT)
      @observability = observability
      @environment = environment
      @queue = Queue.new
      @request_queue = SizedQueue.new(MAX_PENDING_REQUESTS)
      @queue_mutex = Mutex.new
      @queued_bytes = 0
      @stopping = false
      @provider_ready_timeout_seconds = provider_ready_timeout_seconds && Float(provider_ready_timeout_seconds)
      @provider_poll_seconds = Float(provider_poll_seconds)
      @request_read_timeout_seconds = Float(request_read_timeout_seconds)
      @backend_port = Integer(backend_port)
      raise ArgumentError, "provider readiness timeout must be positive" if
        @provider_ready_timeout_seconds && !@provider_ready_timeout_seconds.positive?
      raise ArgumentError, "provider poll interval must be positive" unless @provider_poll_seconds.positive?
      raise ArgumentError, "request read timeout must be positive" unless @request_read_timeout_seconds.positive?
      raise ArgumentError, "backend port is invalid" unless @backend_port.between?(1, 65_535)
    end

    def run
      listeners = activated_sockets
      raise AgentObservability::Error, "launchd provided no Listener socket" if listeners.empty?

      trap_signals(listeners)
      worker = Thread.new { worker_loop }
      request_workers = Array.new(REQUEST_WORKERS) do
        Thread.new { request_worker_loop }
      end
      acceptors = listeners.map do |listener|
        Thread.new do
          until @stopping
            begin
              accepted = listener.accept
              socket = accepted.is_a?(Array) ? accepted.fetch(0) : accepted
              enqueue_request(socket)
            rescue IOError, Errno::EBADF
              break if @stopping
            rescue SystemCallError
              next unless @stopping
            end
          end
        end
      end
      acceptors.each(&:join)
      REQUEST_WORKERS.times { @request_queue << :stop }
      request_workers.each(&:join)
      worker.join
      0
    end

    private

    def activated_sockets
      explicit = @environment["TWO_HEAD_WU_OBSERVABILITY_LISTEN_FD"].to_s
      return [Socket.for_fd(Integer(explicit))] unless explicit.empty?

      handle = Fiddle::Handle::DEFAULT
      activate = Fiddle::Function.new(
        handle["launch_activate_socket"],
        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP],
        Fiddle::TYPE_INT
      )
      pointer_pack = Fiddle::SIZEOF_VOIDP == 8 ? "Q" : "L"
      count_pack = Fiddle::SIZEOF_SIZE_T == 8 ? "Q" : "L"
      descriptors_pointer = Fiddle::Pointer.malloc(Fiddle::SIZEOF_VOIDP)
      count_pointer = Fiddle::Pointer.malloc(Fiddle::SIZEOF_SIZE_T)
      descriptors_pointer[0, Fiddle::SIZEOF_VOIDP] = [0].pack(pointer_pack)
      count_pointer[0, Fiddle::SIZEOF_SIZE_T] = [0].pack(count_pack)
      code = activate.call("Listener", descriptors_pointer, count_pointer)
      raise AgentObservability::Error, "launch_activate_socket failed with code #{code}" unless code.zero?

      address = descriptors_pointer[0, Fiddle::SIZEOF_VOIDP].unpack1(pointer_pack)
      count = count_pointer[0, Fiddle::SIZEOF_SIZE_T].unpack1(count_pack)
      raise AgentObservability::Error, "launchd returned an invalid Listener socket list" if address.zero? || count.zero?

      descriptor_memory = Fiddle::Pointer.new(address)
      descriptors = descriptor_memory[0, count * Fiddle::SIZEOF_INT].unpack("i#{count}")
      free = Fiddle::Function.new(handle["free"], [Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOID)
      free.call(address)
      descriptors.map { |descriptor| Socket.for_fd(descriptor) }
    rescue Fiddle::DLError, ArgumentError => error
      raise AgentObservability::Error, "cannot activate lazy OTLP socket: #{error.message}"
    end

    def trap_signals(listeners)
      %w[TERM INT].each do |signal|
        Signal.trap(signal) do
          @stopping = true
          listeners.each { |listener| listener.close rescue nil }
          @queue << :stop
        end
      end
    end

    def receive_request(socket)
      request_line, headers, body = Timeout.timeout(@request_read_timeout_seconds) do
        read_http_request(socket)
      end
      unless request_line && request_line.match?(/\APOST \/v1\/traces HTTP\/1\.[01]\z/)
        respond(socket, 404)
        record_gap("invalid-otlp-request")
        return
      end

      item = {
        "body" => body,
        "content_type" => headers.fetch("content-type", "application/x-protobuf"),
        "content_encoding" => headers["content-encoding"],
        "phase" => headers["x-two-head-wu-observability-phase"] == "commissioning" ? "commissioning" : nil
      }
      if enqueue(item)
        respond(socket, 202)
      else
        respond(socket, 503)
        record_gap("queue-full", bytes: body.bytesize, phase: item["phase"])
      end
    rescue AgentObservability::Error, Timeout::Error
      respond(socket, 400)
      record_gap("invalid-otlp-request")
    ensure
      socket.close rescue nil
    end

    def enqueue_request(socket)
      @request_queue.push(socket, true)
      true
    rescue ThreadError
      respond(socket, 503)
      record_gap("frontend-overloaded")
      socket.close rescue nil
      false
    end

    def request_worker_loop
      loop do
        socket = @request_queue.pop
        break if socket == :stop

        begin
          receive_request(socket)
        rescue StandardError
          record_gap("proxy-worker-failed")
          socket.close rescue nil
        end
      end
    end

    def read_http_request(socket)
      buffer = +""
      until buffer.include?("\r\n\r\n")
        chunk = socket.readpartial(4096)
        buffer << chunk
        raise AgentObservability::Error, "OTLP headers are too large" if buffer.bytesize > MAX_HEADER_BYTES
      end
      head, body = buffer.split("\r\n\r\n", 2)
      lines = head.lines(chomp: true).map { |line| line.delete_suffix("\r") }
      request_line = lines.shift
      headers = lines.each_with_object({}) do |line, output|
        key, value = line.split(":", 2)
        raise AgentObservability::Error, "invalid OTLP HTTP header" unless key && value
        output[key.downcase] = value.strip
      end
      raise AgentObservability::Error, "chunked OTLP requests are unsupported" if
        headers.fetch("transfer-encoding", "").downcase.include?("chunked")
      length = Integer(headers.fetch("content-length"))
      raise AgentObservability::Error, "invalid OTLP body size" unless length.between?(0, MAX_BODY_BYTES)
      while body.bytesize < length
        body << socket.readpartial([16_384, length - body.bytesize].min)
      end
      [request_line, headers, body.byteslice(0, length)]
    rescue EOFError, KeyError, ArgumentError
      raise AgentObservability::Error, "incomplete OTLP HTTP request"
    end

    def enqueue(item)
      size = item.fetch("body").bytesize
      @queue_mutex.synchronize do
        return false if @queued_bytes + size > MAX_QUEUED_BYTES
        @queued_bytes += size
      end
      @queue << item
      true
    end

    def worker_loop
      loop do
        item = @queue.pop
        break if item == :stop

        begin
          request_provider_start
          unless wait_for_backend
            unless @stopping
              record_gap(
                "provider-start-failed", bytes: item.fetch("body").bytesize, phase: item["phase"]
              )
            end
            next
          end
          forward(item)
        rescue StandardError
          record_gap("proxy-worker-failed", bytes: item.fetch("body").bytesize, phase: item["phase"])
        ensure
          @queue_mutex.synchronize { @queued_bytes -= item.fetch("body").bytesize }
        end
      end
    end

    def request_provider_start
      @observability.send(:signal_provider_trigger)
    end

    def wait_for_backend
      deadline = if @provider_ready_timeout_seconds
                   Process.clock_gettime(Process::CLOCK_MONOTONIC) + @provider_ready_timeout_seconds
                 end
      loop do
        return true if backend_open?
        return false if @stopping
        return false if deadline && Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        request_provider_start
        sleep @provider_poll_seconds
      end
    end

    def backend_open?
      request = Net::HTTP::Post.new("/v1/traces")
      request["Content-Type"] = "application/x-protobuf"
      request.body = "".b
      http = Net::HTTP.new("127.0.0.1", @backend_port)
      http.open_timeout = 0.5
      http.read_timeout = 0.5
      response = http.start { |connection| connection.request(request) }
      response.code.to_i.between?(200, 299)
    rescue SystemCallError, IOError, Timeout::Error, Net::HTTPBadResponse
      false
    end

    def forward(item)
      request = Net::HTTP::Post.new("/v1/traces")
      request["Content-Type"] = item.fetch("content_type")
      request["Content-Encoding"] = item["content_encoding"] if item["content_encoding"]
      request.body = item.fetch("body")
      http = Net::HTTP.new("127.0.0.1", @backend_port)
      http.open_timeout = 2
      http.read_timeout = 15
      response = http.start { |connection| connection.request(request) }
      return if response.code.to_i.between?(200, 299)

      record_gap(
        "backend-forward-failed", bytes: item.fetch("body").bytesize, phase: item["phase"]
      )
    rescue SystemCallError, IOError, Timeout::Error, Net::HTTPBadResponse
      record_gap(
        "backend-forward-failed", bytes: item.fetch("body").bytesize, phase: item["phase"]
      )
    end

    def record_gap(reason, bytes: nil, phase: nil)
      @observability.record_coverage_gap(reason, bytes: bytes, phase: phase)
    rescue StandardError => error
      warn("agent-observability could not record #{reason}: #{error.class}")
      false
    end

    def respond(socket, status)
      reason = { 202 => "Accepted", 400 => "Bad Request", 404 => "Not Found", 503 => "Service Unavailable" }.fetch(status)
      socket.write("HTTP/1.1 #{status} #{reason}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
    rescue IOError, SystemCallError
      nil
    end
  end
end
