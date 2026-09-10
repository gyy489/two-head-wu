# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "pathname"
require "tmpdir"

ROOT = Pathname.new(__dir__).join("../../..").expand_path
ADAPTER = ROOT.join("capabilities/agent-identity/adapters/agent-identity")

PARENT_ID = "11111111-2222-4333-8444-555555555555"
CHILD_ID = "66666666-7777-4888-8999-aaaaaaaaaaaa"

def run_lifecycle(environment, *arguments)
  output, error, status = Open3.capture3(environment, ADAPTER.to_s, "thread-lifecycle", "inspect", *arguments, "--json")
  raise "thread lifecycle failed: #{error}" unless status.success?

  JSON.parse(output)
end

def expect_lifecycle_failure(environment, *arguments)
  _output, error, status = Open3.capture3(environment, ADAPTER.to_s, "thread-lifecycle", "inspect", *arguments, "--json")
  raise "thread lifecycle unexpectedly succeeded" if status.success?
  raise "thread lifecycle did not return a bounded error" unless error.start_with?("Error:")
end

def write_rollout(path, thread_id, forked_from: nil)
  FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
  payload = {
    "session_id" => thread_id,
    "id" => thread_id,
    "timestamp" => "2026-08-27T00:00:00Z",
    "cwd" => "/synthetic",
    "originator" => "test",
    "cli_version" => "test",
    "source" => "cli",
    "model_provider" => "test"
  }
  if forked_from
    payload["forked_from_id"] = forked_from
    payload["history_base"] = {
      "thread_id" => forked_from,
      "end_ordinal_exclusive" => 12,
      "end_byte_offset" => 4096
    }
  end
  first = JSON.generate("timestamp" => "2026-08-27T00:00:00Z", "type" => "session_meta", "payload" => payload)
  # The second record is deliberately invalid JSON. A passing inspection proves
  # the interface does not scan turns or message bodies.
  File.write(path, "#{first}\nthis-is-not-a-readable-turn\n", mode: "w", perm: 0o600)
end

Dir.mktmpdir("two-head-wu-thread-lifecycle-") do |temporary|
  codex_home = File.join(temporary, "codex-home")
  parent_rollout = File.join(codex_home, "sessions", "2026", "08", "27", "rollout-parent-#{PARENT_ID}.jsonl")
  child_rollout = File.join(codex_home, "sessions", "2026", "08", "27", "rollout-child-#{CHILD_ID}.jsonl")
  write_rollout(parent_rollout, PARENT_ID)
  write_rollout(child_rollout, CHILD_ID, forked_from: PARENT_ID)

  database = File.join(codex_home, "state_5.sqlite")
  sql = <<~SQL
    CREATE TABLE threads (
      id TEXT PRIMARY KEY,
      rollout_path TEXT NOT NULL,
      archived INTEGER NOT NULL DEFAULT 0
    );
    INSERT INTO threads(id, rollout_path, archived) VALUES(
      '#{PARENT_ID}', '#{parent_rollout.gsub("'", "''")}', 0
    );
    INSERT INTO threads(id, rollout_path, archived) VALUES(
      '#{CHILD_ID}', '#{child_rollout.gsub("'", "''")}', 0
    );
  SQL
  _output, error, status = Open3.capture3("sqlite3", database, sql)
  raise "could not create lifecycle fixture: #{error}" unless status.success?
  File.chmod(0o600, database)

  environment = { "CODEX_HOME" => codex_home, "CODEX_THREAD_ID" => CHILD_ID }
  active = run_lifecycle(environment)
  raise "lifecycle schema drift" unless active.fetch("schema") == "two-head-wu.thread-lifecycle.v1"
  raise "lifecycle result is not verified" unless active.fetch("verified") == true
  raise "database identifier leaked a path" unless active.fetch("database_id").start_with?("sha256:")
  child = active.fetch("threads").fetch(0)
  raise "current UUID was not selected exactly" unless child.fetch("thread_id") == CHILD_ID
  raise "active state was not observed" unless child.fetch("lifecycle") == "active" && child.fetch("archived") == false
  raise "thread creation time was not read from session metadata" unless child.fetch("created_at") == "2026-08-27T00:00:00Z"
  raise "native fork source was not read from session metadata" unless child.fetch("forked_from_thread_id") == PARENT_ID
  raise "native fork byte boundary was not verified" unless child.dig("fork_point", "source_thread_id") == PARENT_ID && child.dig("fork_point", "end_byte_offset") == 4096
  raise "rollout end position was not observed" unless child.fetch("rollout_end_byte_offset").is_a?(Integer) && child.fetch("rollout_end_byte_offset").positive?
  raise "rollout path leaked from the lifecycle interface" if child.key?("rollout_path")

  both = run_lifecycle(environment, "--thread", PARENT_ID, "--thread", CHILD_ID).fetch("threads")
  raise "multi-thread inspection lost exact order" unless both.map { |item| item.fetch("thread_id") } == [PARENT_ID, CHILD_ID]
  raise "parent was incorrectly treated as a fork" unless both.first.fetch("forked_from_thread_id").nil?

  existence_only = run_lifecycle(environment, "--thread", CHILD_ID, "--existence-only").fetch("threads").fetch(0)
  raise "existence-only inspection lost active state" unless existence_only.fetch("lifecycle") == "active"
  raise "existence-only inspection parsed fork metadata" unless existence_only.fetch("created_at").nil? && existence_only.fetch("forked_from_thread_id").nil? && existence_only.fetch("fork_point").nil?

  _output, error, status = Open3.capture3("sqlite3", database, "UPDATE threads SET archived=1 WHERE id='#{CHILD_ID}';")
  raise "could not archive lifecycle fixture: #{error}" unless status.success?
  archived = run_lifecycle(environment).fetch("threads").fetch(0)
  raise "archive state was not observed" unless archived.fetch("lifecycle") == "archived" && archived.fetch("archived") == true

  _output, error, status = Open3.capture3("sqlite3", database, "UPDATE threads SET archived=0 WHERE id='#{CHILD_ID}';")
  raise "could not unarchive lifecycle fixture: #{error}" unless status.success?
  unarchived = run_lifecycle(environment).fetch("threads").fetch(0)
  raise "unarchive state was not observed" unless unarchived.fetch("lifecycle") == "active"

  _output, error, status = Open3.capture3("sqlite3", database, "DELETE FROM threads WHERE id='#{CHILD_ID}';")
  raise "could not delete lifecycle fixture: #{error}" unless status.success?
  missing = run_lifecycle(environment).fetch("threads").fetch(0)
  raise "delete was not observed deterministically" unless missing.fetch("lifecycle") == "missing" && missing.fetch("exists") == false

  expect_lifecycle_failure(environment, "--thread", "not-a-uuid")
  expect_lifecycle_failure(environment.merge("CODEX_THREAD_ID" => nil))
end

puts "thread lifecycle tests ok"
