# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "pathname"
require "time"

class CodexThreadLifecycleError < StandardError; end

# Reads only Codex's thread index and the first session_meta record of a
# rollout. It never reads turns, messages, credentials, or account data.
class CodexThreadLifecycle
  UUID_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i.freeze
  STATE_DATABASE = "state_5.sqlite"
  SESSION_META_LIMIT = 2 * 1024 * 1024

  def initialize(environment: ENV, sqlite_command: "sqlite3")
    @environment = environment
    @sqlite_command = sqlite_command
  end

  def inspect_threads(thread_ids: nil, include_session_metadata: true)
    ids = normalize_thread_ids(thread_ids)
    database = current_database
    rows = query_threads(database, ids)
    database_id = database_identifier(database)

    {
      "schema" => "two-head-wu.thread-lifecycle.v1",
      "verified" => true,
      "database_id" => database_id,
      "threads" => ids.map { |thread_id| thread_payload(thread_id, rows[thread_id], database_id, include_session_metadata) }
    }
  end

  private

  def normalize_thread_ids(thread_ids)
    values = Array(thread_ids).compact
    values = [@environment["CODEX_THREAD_ID"]] if values.empty?
    raise CodexThreadLifecycleError, "CODEX_THREAD_ID is unavailable" if values.empty? || values.first.to_s.empty?

    values.map do |value|
      thread_id = value.to_s.downcase
      raise CodexThreadLifecycleError, "thread ID must be a UUID" unless UUID_PATTERN.match?(thread_id)

      thread_id
    end.uniq
  end

  def current_database
    raw_home = @environment["CODEX_HOME"]
    raise CodexThreadLifecycleError, "CODEX_HOME is unavailable" if raw_home.to_s.empty?

    home = Pathname.new(raw_home.to_s).expand_path.cleanpath
    raise CodexThreadLifecycleError, "CODEX_HOME must be an absolute directory" unless home.absolute? && home.directory?

    database = home.join(STATE_DATABASE)
    raise CodexThreadLifecycleError, "Codex thread index is unavailable" unless database.file?

    database
  end

  def query_threads(database, ids)
    columns = sqlite_rows(database, "PRAGMA table_info(threads)").map { |row| row.fetch("name") }
    required = %w[id rollout_path archived]
    missing = required - columns
    unless missing.empty?
      raise CodexThreadLifecycleError, "Codex thread index is missing required metadata columns"
    end

    id_list = ids.map { |thread_id| sqlite_literal(thread_id) }.join(", ")
    sqlite_rows(database, "SELECT id, rollout_path, archived FROM threads WHERE id IN (#{id_list})").each_with_object({}) do |row, output|
      output[row.fetch("id").downcase] = row
    end
  end

  def thread_payload(thread_id, row, database_id, include_session_metadata)
    unless row
      return {
        "thread_id" => thread_id,
        "lifecycle" => "missing",
        "exists" => false,
        "archived" => nil,
        "created_at" => nil,
        "forked_from_thread_id" => nil,
        "fork_point" => nil,
        "rollout_end_byte_offset" => nil,
        "database_id" => database_id
      }
    end

    archived = row.fetch("archived").to_i == 1
    metadata = include_session_metadata ? session_metadata(row.fetch("rollout_path"), thread_id) : {
      "created_at" => nil,
      "forked_from_thread_id" => nil,
      "fork_point" => nil,
      "rollout_end_byte_offset" => nil
    }
    {
      "thread_id" => thread_id,
      "lifecycle" => archived ? "archived" : "active",
      "exists" => true,
      "archived" => archived,
      "created_at" => metadata.fetch("created_at"),
      "forked_from_thread_id" => metadata.fetch("forked_from_thread_id"),
      "fork_point" => metadata.fetch("fork_point"),
      "rollout_end_byte_offset" => metadata.fetch("rollout_end_byte_offset"),
      "database_id" => database_id
    }
  end

  def session_metadata(raw_path, thread_id)
    path = Pathname.new(raw_path.to_s).expand_path.cleanpath
    raise CodexThreadLifecycleError, "thread rollout metadata is unavailable" unless path.file?

    first_line = nil
    File.open(path.to_s, "rb") do |file|
      first_line = file.gets(SESSION_META_LIMIT + 1)
    end
    if first_line.nil? || first_line.bytesize > SESSION_META_LIMIT
      raise CodexThreadLifecycleError, "thread session metadata is missing or too large"
    end

    record = JSON.parse(first_line)
    payload = record["payload"]
    unless record["type"] == "session_meta" && payload.is_a?(Hash)
      raise CodexThreadLifecycleError, "thread rollout does not start with session metadata"
    end
    recorded_id = (payload["id"] || payload["session_id"]).to_s.downcase
    raise CodexThreadLifecycleError, "thread session metadata ID does not match the index" unless recorded_id == thread_id

    created_at = payload["timestamp"].to_s
    begin
      Time.iso8601(created_at)
    rescue ArgumentError
      raise CodexThreadLifecycleError, "thread creation timestamp is invalid"
    end

    source = payload["forked_from_id"] || payload["forkedFromId"]
    if source.to_s.empty?
      return {
        "created_at" => created_at,
        "forked_from_thread_id" => nil,
        "fork_point" => nil,
        "rollout_end_byte_offset" => path.size
      }
    end

    value = source.to_s.downcase
    raise CodexThreadLifecycleError, "fork source in session metadata is not a UUID" unless UUID_PATTERN.match?(value)

    history_base = payload["history_base"]
    unless history_base.is_a?(Hash) && history_base["thread_id"].to_s.downcase == value &&
           history_base["end_byte_offset"].is_a?(Integer) && history_base["end_byte_offset"] >= 0 &&
           history_base["end_ordinal_exclusive"].is_a?(Integer) && history_base["end_ordinal_exclusive"] >= 0
      raise CodexThreadLifecycleError, "native fork point metadata is missing or invalid"
    end

    {
      "created_at" => created_at,
      "forked_from_thread_id" => value,
      "fork_point" => {
        "source_thread_id" => value,
        "end_byte_offset" => history_base.fetch("end_byte_offset"),
        "end_ordinal_exclusive" => history_base.fetch("end_ordinal_exclusive")
      },
      "rollout_end_byte_offset" => path.size
    }
  rescue JSON::ParserError
    raise CodexThreadLifecycleError, "thread session metadata is invalid"
  rescue Errno::EACCES, Errno::ENOENT
    raise CodexThreadLifecycleError, "thread rollout metadata is unavailable"
  end

  def sqlite_rows(database, sql)
    output, error, status = Open3.capture3(@sqlite_command, "-readonly", "-json", database.to_s, sql)
    raise CodexThreadLifecycleError, "Codex thread index could not be read" unless status.success?

    output.strip.empty? ? [] : JSON.parse(output)
  rescue Errno::ENOENT
    raise CodexThreadLifecycleError, "sqlite3 command is unavailable"
  rescue JSON::ParserError
    raise CodexThreadLifecycleError, "Codex thread index returned invalid metadata"
  end

  def database_identifier(database)
    canonical = File.realpath(database.to_s)
    "sha256:#{Digest::SHA256.hexdigest(canonical)}"
  rescue Errno::ENOENT, Errno::EACCES
    raise CodexThreadLifecycleError, "Codex thread index is unavailable"
  end

  def sqlite_literal(value)
    "'#{value.to_s.gsub("'", "''")}'"
  end
end
