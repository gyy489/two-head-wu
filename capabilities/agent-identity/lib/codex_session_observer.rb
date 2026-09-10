# frozen_string_literal: true

require "open3"
require "pathname"

# Runs an interactive Codex child on the caller's real TTY and observes only
# filenames that the child itself has open. Rollout contents are never read.
class CodexSessionObserver
  Result = Struct.new(:exit_code, :thread_id, :signal, keyword_init: true)
  ObserverUnavailable = Class.new(StandardError)
  UUID_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i.freeze
  ROLLOUT_PATTERN = /rollout-[^\/]*-([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl\z/i.freeze

  def initialize(allowed_roots:, lsof_command: default_lsof_command, poll_interval: 0.2, max_poll_interval: 5.0)
    @allowed_roots = allowed_roots.map { |root| normalize_root(root) }.compact.uniq.freeze
    @lsof_command = lsof_command
    @poll_interval = poll_interval
    @max_poll_interval = max_poll_interval
  end

  def run(environment, *command, expected_thread_id: nil, on_thread_observed: nil)
    expected = normalize_uuid(expected_thread_id)
    pid = Process.spawn(environment, *command)
    stop_mutex = Mutex.new
    stop_condition = ConditionVariable.new
    stopped = false
    observer = Thread.new do
      Thread.current.report_on_exception = false
      thread_id = observe(pid, expected) do |interval|
        stop_mutex.synchronize do
          stop_condition.wait(stop_mutex, interval) unless stopped
          stopped
        end
      end
      begin
        on_thread_observed.call(thread_id) if thread_id && on_thread_observed
      rescue StandardError
        # Losing optional bookkeeping must never terminate the interactive Codex
        # child or hide the thread UUID that was successfully observed.
      end
      thread_id
    end

    status = wait_like_system(pid)
    stop_mutex.synchronize do
      stopped = true
      stop_condition.broadcast
    end
    observer.join
    thread_id = observer.value
    Result.new(exit_code: exit_code(status), thread_id: thread_id, signal: status.signaled? ? status.termsig : nil)
  ensure
    if defined?(stop_mutex) && stop_mutex
      stop_mutex.synchronize do
        stopped = true
        stop_condition&.broadcast
      end
    end
    observer&.join
  end

  private

  def observe(pid, expected)
    interval = @poll_interval
    loop do
      candidates = open_rollout_ids(pid)
      return expected if expected && candidates.include?(expected)
      return candidates.first if expected.nil? && candidates.one?
      return nil if yield(interval)
      interval = [interval * 2, @max_poll_interval].min
    end
  rescue StandardError
    nil
  end

  def open_rollout_ids(pid)
    output, _error, _status = Open3.capture3(*@lsof_command, "-a", "-p", pid.to_s, "-Fn")
    output.each_line.map do |line|
      next unless line.start_with?("n")

      path = line.delete_prefix("n").strip
      next unless inside_allowed_root?(path)

      match = ROLLOUT_PATTERN.match(path)
      match && match[1].downcase
    end.compact.uniq
  rescue Errno::ENOENT
    raise ObserverUnavailable, "lsof is unavailable"
  end

  def inside_allowed_root?(path)
    @allowed_roots.any? { |root| path.start_with?("#{root}#{File::SEPARATOR}") }
  end

  def normalize_root(root)
    path = Pathname.new(root.to_s).expand_path.cleanpath
    path = path.realpath if path.exist?
    path.to_s
  rescue Errno::ENOENT, Errno::EACCES
    nil
  end

  def normalize_uuid(value)
    return nil if value.nil?

    text = value.to_s.downcase
    UUID_PATTERN.match?(text) ? text : nil
  end

  def wait_like_system(pid)
    previous_interrupt = Signal.trap("INT", "IGNORE")
    previous_quit = Signal.trap("QUIT", "IGNORE")
    Process.wait2(pid).last
  ensure
    Signal.trap("INT", previous_interrupt) if previous_interrupt
    Signal.trap("QUIT", previous_quit) if previous_quit
  end

  def exit_code(status)
    status.exitstatus || 128 + status.termsig.to_i
  end

  def default_lsof_command
    File.executable?("/usr/sbin/lsof") ? ["/usr/sbin/lsof"] : ["lsof"]
  end
end
