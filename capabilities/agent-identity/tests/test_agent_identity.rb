#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "digest"
require "json"
require "open3"
require "pathname"
require "tmpdir"
require "time"

ROOT = Pathname.new(__dir__).join("../../..").expand_path
ADAPTER = ROOT.join("capabilities/agent-identity/adapters/agent-identity")

def run!(environment, *arguments)
  output, error, status = Open3.capture3(environment, ADAPTER.to_s, *arguments)
  raise "#{arguments.join(' ')} failed: #{error}" unless status.success?

  output
end

def run_with_input!(environment, input, *arguments)
  output, error, status = Open3.capture3(environment, ADAPTER.to_s, *arguments, stdin_data: input)
  raise "#{arguments.join(' ')} failed: #{error}" unless status.success?

  output
end

def fail_run!(environment, *arguments)
  _output, error, status = Open3.capture3(environment, ADAPTER.to_s, *arguments)
  raise "#{arguments.join(' ')} unexpectedly succeeded" if status.success?
  raise "#{arguments.join(' ')} did not report an error" unless error.start_with?("Error:")
end

def create_state_database(path, threads)
  FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
  statements = threads.map do |thread|
    values = %i[id rollout_path title].map { |key| "'#{thread.fetch(key).to_s.gsub("'", "''")}'" }
    name = thread.fetch(:name, thread.fetch(:title)).to_s.gsub("'", "''")
    cwd = thread.fetch(:cwd, File.dirname(thread.fetch(:rollout_path))).to_s.gsub("'", "''")
    archived = thread.fetch(:archived, 0)
    "INSERT INTO threads(id, rollout_path, updated_at, updated_at_ms, title, name, cwd, archived) VALUES(#{values[0]}, #{values[1]}, #{thread.fetch(:updated_at)}, #{thread.fetch(:updated_at) * 1000}, #{values[2]}, '#{name}', '#{cwd}', #{archived});"
  end
  sql = <<~SQL
    CREATE TABLE thread_sections (id TEXT PRIMARY KEY, name TEXT NOT NULL);
    CREATE TABLE projects (id TEXT PRIMARY KEY, name TEXT NOT NULL);
    CREATE TABLE project_roots (project_id TEXT NOT NULL, position INTEGER NOT NULL, path TEXT NOT NULL, PRIMARY KEY(project_id, position));
    CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL, updated_at INTEGER NOT NULL, updated_at_ms INTEGER, title TEXT NOT NULL, name TEXT, cwd TEXT, archived INTEGER NOT NULL DEFAULT 0);
    CREATE TABLE thread_dynamic_tools (thread_id TEXT NOT NULL, position INTEGER NOT NULL, name TEXT NOT NULL, PRIMARY KEY(thread_id, position));
    CREATE TABLE thread_spawn_edges (parent_thread_id TEXT NOT NULL, child_thread_id TEXT NOT NULL PRIMARY KEY, status TEXT NOT NULL);
    #{statements.join("\n")}
  SQL
  _output, error, status = Open3.capture3("sqlite3", path, sql)
  raise "could not create state fixture: #{error}" unless status.success?
  File.chmod(0o600, path)
end

Dir.mktmpdir("two-head-wu-agent-identity-") do |temporary|
  home = File.join(temporary, "home")
  private_root = File.join(temporary, "private", "agent-identity")
  active_skills_root = File.join(temporary, "active-skills")
  FileUtils.mkdir_p(File.join(home, ".codex"), mode: 0o700)
  FileUtils.mkdir_p(active_skills_root, mode: 0o700)
  environment = {
    "HOME" => home,
    "TWO_HEAD_WU_IDENTITY_ROOT" => private_root,
    "TWO_HEAD_WU_TESTING" => "1",
    "TWO_HEAD_WU_TEST_ACTIVE_SKILLS_ROOT" => active_skills_root
  }

  run!(environment, "init")
  raise "private root mode is not 0700" unless (File.stat(private_root).mode & 0o777) == 0o700

  # Simulate months of pre-existing session history in the native ~/.codex, produced
  # before this identity was ever registered, to prove register-current sweeps
  # historical sessions into the default pool instead of leaving them behind.
  historical_home = File.join(home, ".codex")
  FileUtils.mkdir_p(File.join(historical_home, "sessions", "2026", "02"))
  File.write(File.join(historical_home, "sessions", "2026", "02", "historical.jsonl"), "{}\n")
  FileUtils.mkdir_p(File.join(historical_home, "archived_sessions"))
  File.write(File.join(historical_home, "archived_sessions", "old-rollout.jsonl"), "{}\n")

  registration = run!(environment, "register-current", "--alias", "member-two")
  raise "default identity was not registered" unless registration.include?("identity: member-two") && registration.include?("state_kind: default")
  raise "register-current did not report the default pool" unless registration.include?("conversation_pool: main")

  status = JSON.parse(run!(environment, "status", "--json"))
  identity = status.fetch("identities").find { |item| item.fetch("id") == "member-two" }
  raise "status leaks an unexpected field" unless identity.keys.sort == %w[configured conversation_pool id selection_mode shared_skills state_kind usage_scope]
  raise "legacy owner identity usage scope drift" unless identity.fetch("usage_scope") == "owner-local"
  raise "default identity state is wrong" unless identity.fetch("state_kind") == "default" && identity.fetch("configured")
  raise "default identity did not default into the main pool" unless identity.fetch("conversation_pool") == "main"
  raise "default sessions dir was not linked into the pool" unless File.symlink?(File.join(historical_home, "sessions"))
  raise "default archived_sessions dir was not linked into the pool" unless File.symlink?(File.join(historical_home, "archived_sessions"))
  historical_in_pool = File.join(private_root, "conversation-pools", "main", "sessions", "2026", "02", "historical.jsonl")
  raise "pre-existing history was not migrated into the default pool" unless File.exist?(historical_in_pool)
  raise "pre-existing archive was not migrated into the default pool" unless File.exist?(File.join(private_root, "conversation-pools", "main", "archived_sessions", "old-rollout.jsonl"))
  default_home = JSON.parse(run!(environment, "home", "--alias", "member-two", "--json"))
  raise "default home did not resolve to native Codex home" unless default_home.fetch("codex_home") == File.join(home, ".codex")
  ascii_environment = environment.merge("LANG" => "C", "LC_ALL" => "C")
  ascii_home = JSON.parse(run!(ascii_environment, "home", "--alias", "member-two", "--json"))
  raise "home command failed under an ASCII process locale" unless ascii_home.fetch("codex_home") == File.join(home, ".codex")
  fail_run!(environment, "register-current", "--alias", "second-default")

  added = run!(environment, "add", "--alias", "study", "--mode", "project-auto")
  raise "isolated identity was not created" unless added.include?("identity: study") && added.include?("state_kind: isolated")
  raise "add did not report the default pool" unless added.include?("conversation_pool: main")
  isolated_home = File.join(private_root, "codex-homes", "study")
  isolated_home_result = JSON.parse(run!(environment, "home", "--alias", "study", "--json"))
  raise "isolated home did not resolve to the private Codex home" unless isolated_home_result.fetch("codex_home") == isolated_home
  raise "isolated home mode is not 0700" unless (File.stat(isolated_home).mode & 0o777) == 0o700
  shared_skills = File.join(isolated_home, "skills")
  raise "isolated identity does not link the shared Skill surface" unless File.symlink?(shared_skills)
  raise "isolated identity links the wrong Skill surface" unless File.realpath(shared_skills) == File.realpath(active_skills_root)

  # add() attaches to the "main" pool before any caller ever touches sessions, so
  # writing through the identity's (now-symlinked) session paths lands straight in
  # the shared pool with no separate pool-create/pool-attach step required.
  File.write(File.join(historical_home, "sessions", "2026", "02", "default-new.jsonl"), "{}\n")
  FileUtils.mkdir_p(File.join(isolated_home, "sessions", "2026"))
  File.write(File.join(isolated_home, "sessions", "2026", "study.jsonl"), "{}\n")
  pool_status = JSON.parse(run!(environment, "pool-status", "--json"))
  pool = pool_status.fetch("pools").find { |item| item.fetch("id") == "main" }
  raise "conversation pool was not registered" unless pool.fetch("identities") == %w[member-two study]
  %w[sessions archived_sessions attachments].each do |name|
    default_link = File.join(historical_home, name)
    study_link = File.join(isolated_home, name)
    raise "default #{name} was not linked to the pool" unless File.symlink?(default_link)
    raise "study #{name} was not linked to the pool" unless File.symlink?(study_link)
  end
  pool_sessions = File.join(private_root, "conversation-pools", "main", "sessions", "2026")
  raise "new default session did not land in the pool" unless File.exist?(File.join(pool_sessions, "02", "default-new.jsonl"))
  raise "study session did not land in the pool" unless File.exist?(File.join(pool_sessions, "study.jsonl"))

  # --no-pool opts an identity out of the default; it must stay unpooled and unlinked.
  solo_added = run!(environment, "add", "--alias", "solo", "--mode", "manual", "--no-pool")
  raise "opted-out identity was not created" unless solo_added.include?("conversation_pool: none")
  solo_home = File.join(private_root, "codex-homes", "solo")
  solo_identity = JSON.parse(run!(environment, "status", "--json")).fetch("identities").find { |item| item.fetch("id") == "solo" }
  raise "opted-out identity should not carry a conversation_pool" unless solo_identity.fetch("conversation_pool").nil?
  raise "opted-out identity should not have its sessions dir linked" if File.symlink?(File.join(solo_home, "sessions"))

  # --pool NAME routes an identity into a pool other than the default.
  side_added = run!(environment, "add", "--alias", "sat", "--mode", "manual", "--pool", "side")
  raise "custom-pool identity was not created" unless side_added.include?("conversation_pool: side")
  side_pool = JSON.parse(run!(environment, "pool-status", "--json")).fetch("pools").find { |item| item.fetch("id") == "side" }
  raise "custom pool was not created with the new identity" unless side_pool && side_pool.fetch("identities") == %w[sat]
  raise "custom-pool identity leaked into the default pool" if pool.fetch("identities").include?("sat")

  fail_run!(environment, "add", "--alias", "conflicting", "--pool", "side", "--no-pool")

  member = JSON.parse(run!(environment, "add-member", "--alias", "classmate-mini", "--json"))
  unless member.slice("result", "identity", "state_kind", "mode", "usage_scope", "shared_skills", "conversation_pool") == {
    "result" => "member-added",
    "identity" => "classmate-mini",
    "state_kind" => "isolated",
    "mode" => "manual",
    "usage_scope" => "member-remote-work",
    "shared_skills" => "none",
    "conversation_pool" => "none"
  }
    raise "member identity creation did not enforce its closed isolation profile"
  end
  member_home = JSON.parse(run!(environment, "member-home", "--alias", "classmate-mini", "--json"))
  raise "member-home did not return the fixed member identity" unless member_home.fetch("identity") == "classmate-mini" && member_home.fetch("usage_scope") == "member-remote-work"
  raise "member identity inherited the owner Skill surface" if File.exist?(File.join(member_home.fetch("codex_home"), "skills"))
  run!(environment, "login", "--alias", "classmate-mini", "--dry-run")
  fail_run!(environment, "member-home", "--alias", "study", "--json")
  fail_run!(environment, "set-mode", "--alias", "classmate-mini", "--mode", "project-auto")
  fail_run!(environment, "bind", "--project", "member-project", "--alias", "classmate-mini")
  fail_run!(environment, "pool-attach", "--pool", "main", "--alias", "classmate-mini")
  fail_run!(environment, "route-set", "--channel", "openclaw-weixin", "--session", "member-session", "--alias", "classmate-mini", "--json")
  fail_run!(environment, "route-command", "--channel", "openclaw-weixin", "--session", "member-session", "--text", "/classmate-mini", "--json")
  fail_run!(environment, "launch", "--alias", "classmate-mini", "--dry-run", "--")
  fail_run!(environment, "make-default", "--alias", "classmate-mini", "--json")
  fail_run!(environment, "add-member", "--alias", "owner-primary", "--json")

  run!(environment, "bind", "--project", "thesis", "--alias", "study")
  selected = JSON.parse(run!(environment, "select", "--project", "thesis", "--json"))
  raise "automatic binding did not resolve" unless selected.fetch("identity") == "study"
  run!(environment, "bind", "--project", "two-head-wu", "--alias", "study")
  route_default = JSON.parse(run!(environment, "route-select", "--channel", "openclaw-weixin", "--session", "peer@example", "--json"))
  raise "route did not fall back to project default" unless route_default.fetch("identity") == "study"
  raise "route fallback source was not reported" unless route_default.fetch("source") == "project-binding"
  route_update = JSON.parse(run!(environment, "route-command", "--channel", "openclaw-weixin", "--session", "peer@example", "--text", "/member-two", "--json"))
  raise "slash route did not switch identity" unless route_update.fetch("identity") == "member-two"
  route_selected = JSON.parse(run!(environment, "route-select", "--channel", "openclaw-weixin", "--session", "peer@example", "--json"))
  raise "route did not remember the selected identity" unless route_selected.fetch("identity") == "member-two"
  raise "explicit route source was not reported" unless route_selected.fetch("source") == "channel-route"
  route_case_selected = JSON.parse(run!(environment, "route-select", "--channel", "openclaw-weixin", "--session", "PEER@example", "--json"))
  raise "route lookup should tolerate OpenClaw session key case normalization" unless route_case_selected.fetch("identity") == "member-two"
  route_prefixed_selected = JSON.parse(run!(environment, "route-select", "--channel", "openclaw-weixin", "--session", "openclaw-weixin:peer@example", "--json"))
  raise "route lookup should normalize channel-prefixed session IDs" unless route_prefixed_selected.fetch("identity") == "member-two"
  route_full_key_selected = JSON.parse(run!(environment, "route-select", "--channel", "openclaw-weixin", "--session", "agent:main:openclaw-weixin:account:direct:peer@example", "--json"))
  raise "route lookup should normalize full OpenClaw session keys" unless route_full_key_selected.fetch("identity") == "member-two"
  route_set = JSON.parse(run!(environment, "route-set", "--channel", "openclaw-weixin", "--session", "openclaw-weixin:peer@example", "--alias", "study", "--json"))
  raise "explicit route did not switch identity" unless route_set.fetch("identity") == "study"
  route_status = JSON.parse(run!(environment, "route-status", "--json"))
  raise "route storage did not collapse equivalent session IDs" unless route_status.fetch("channel_routes") == { "openclaw-weixin:peer@example" => "study" }
  fail_run!(environment, "route-command", "--channel", "openclaw-weixin", "--session", "peer@example", "--text", "/missing")

  launch = run!(environment, "launch", "--project", "thesis", "--dry-run", "--", "--full-auto")
  raise "automatic launch did not select isolated identity" unless launch.include?("identity: study") && launch.include?("state_kind: isolated") && launch.include?("argument_count: 1")
  default_launch = run!(environment, "launch", "--alias", "member-two", "--dry-run")
  raise "default launch is not reported as a fresh session" unless default_launch.include?("identity: member-two") && default_launch.include?("state_kind: default") && default_launch.include?("launch_mode: fresh")
  slot_dry_run = run!(environment.merge("TWO_HEAD_WU_TERMINAL_SLOT" => "论文窗口"), "launch", "--alias", "study", "--dry-run")
  raise "legacy terminal slot changed the launch mode" unless slot_dry_run.include?("launch_mode: fresh") && !slot_dry_run.include?("terminal_slot:")

  # Interactive launch is session-first: a bare launch is fresh, a named resume
  # works across identities, and Codex's native thread name owns the terminal title.
  # Explicit non-interactive Codex subcommands remain untouched. Legacy slot state
  # may still be cleaned up, but it cannot affect a new launch.
  fake_bin = File.join(temporary, "bin")
  FileUtils.mkdir_p(fake_bin)
  fake_app_server = File.join(temporary, "fake-app-server.rb")
  File.write(fake_app_server, <<~RUBY)
    #!/usr/bin/env ruby
    require "json"
    while (line = STDIN.gets)
      message = JSON.parse(line)
      if (log = ENV["CODEX_TEST_NAME_LOG"])
        File.open(log, "a") { |file| file.puts(JSON.generate(message)) }
      end
      next unless message.key?("id")
      STDOUT.puts(JSON.generate("id" => message.fetch("id"), "result" => {}))
      STDOUT.flush
    end
  RUBY
  File.chmod(0o755, fake_app_server)
  fake_codex = File.join(fake_bin, "codex")
  File.write(fake_codex, <<~SH)
    #!/bin/sh
    if [ "$1" = "app-server" ]; then
      printf '%s|%s\\n' "${CODEX_HOME-unset}" "$*" >> "$CODEX_TEST_LOG"
      exec ruby "$CODEX_TEST_APP_SERVER"
    fi
    if [ -n "${TWO_HEAD_WU_TERMINAL_SLOT-}" ] || [ -n "${TWO_HEAD_WU_CODEX_ALIAS-}" ] || [ -n "${TWO_HEAD_WU_TERMINAL_INSTANCE_ID-}" ] || [ -n "${TWO_HEAD_WU_PROJECT_TERMINAL_ID-}" ] || [ -n "${TWO_HEAD_WU_PROJECT_ID-}" ]; then
      exit 23
    fi
    printf '%s|%s\\n' "${CODEX_HOME-unset}" "$*" >> "$CODEX_TEST_LOG"
    if [ -n "${CODEX_TEST_ROLLOUT_PATH-}" ]; then
      exec 8>> "$CODEX_TEST_ROLLOUT_PATH"
      if [ -n "${CODEX_TEST_SECOND_ROLLOUT_PATH-}" ]; then
        exec 9>> "$CODEX_TEST_SECOND_ROLLOUT_PATH"
      fi
      sleep 0.4
    fi
    if [ -n "${CODEX_TEST_SIGNAL-}" ]; then
      kill -"$CODEX_TEST_SIGNAL" $$
    fi
    case " $* " in
      *" resume "*) [ "${CODEX_TEST_FAIL_RESUME-0}" = "1" ] && exit 7 ;;
    esac
    exit 0
  SH
  File.chmod(0o755, fake_codex)
  launch_log = File.join(temporary, "codex-launch.log")
  name_log = File.join(temporary, "codex-name.log")
  launch_environment = environment.merge(
    "PATH" => "#{fake_bin}:#{ENV.fetch('PATH', '')}",
    "CODEX_TEST_LOG" => launch_log,
    "CODEX_TEST_APP_SERVER" => fake_app_server,
    "CODEX_TEST_NAME_LOG" => name_log
  )
  run!(launch_environment, "launch", "--alias", "study")
  first_launch = File.readlines(launch_log, chomp: true).last
  title_option = '--config tui.terminal_title=["thread"]'
  raise "interactive launch did not start a fresh titled session" unless first_launch == "#{isolated_home}|#{title_option}"

  slot_environment = launch_environment.merge("TWO_HEAD_WU_TERMINAL_SLOT" => "论文窗口")
  config_path = File.join(isolated_home, "config.toml")
  File.write(config_path, "model = \"keep-user-config\"\n")
  profile_path = File.join(isolated_home, "two-head-wu-terminal.config.toml")
  File.write(profile_path, "conflicting legacy profile\n")
  run!(slot_environment, "launch", "--alias", "study")
  legacy_slot_launch = File.readlines(launch_log, chomp: true).last
  raise "legacy terminal slot affected a fresh launch" unless legacy_slot_launch == "#{isolated_home}|#{title_option}"
  raise "launch rewrote the conflicting legacy profile" unless File.read(profile_path) == "conflicting legacy profile\n"
  raise "terminal profile overwrote the user's config" unless File.read(config_path) == "model = \"keep-user-config\"\n"

  session_id = "019d1234-5678-7abc-9def-0123456789ab"
  hook_payload = JSON.generate(
    "session_id" => session_id,
    "cwd" => ROOT.to_s,
    "hook_event_name" => "SessionStart",
    "source" => "resume",
    "model" => "test-model"
  )
  hook_output = run_with_input!(
    slot_environment.merge("TWO_HEAD_WU_CODEX_ALIAS" => "study"),
    hook_payload,
    "terminal-session", "hook"
  )
  raise "SessionStart hook leaked model-visible stdout" unless hook_output.empty?
  slot_status = JSON.parse(run!(environment, "terminal-session", "status", "--slot", "论文窗口", "--json"))
  binding = slot_status.fetch("binding")
  raise "SessionStart hook stored the wrong session" unless binding.fetch("session_id") == session_id
  raise "SessionStart hook stored the wrong identity" unless binding.fetch("identity") == "study"
  naming_requests = File.readlines(name_log, chomp: true).map { |line| JSON.parse(line) }
  naming_request = naming_requests.find { |item| item["method"] == "thread/name/set" }
  unless naming_request && naming_request.fetch("params") == { "threadId" => session_id, "name" => "论文窗口" }
    raise "SessionStart hook did not name the selected Codex thread"
  end

  run!(slot_environment, "launch", "--alias", "study", "--", "resume", "论文窗口")
  exact_launch = File.readlines(launch_log, chomp: true).last
  unless exact_launch == "#{isolated_home}|#{title_option} resume 论文窗口"
    raise "isolated identity did not resume the named session"
  end
  run!(slot_environment, "launch", "--alias", "member-two", "--", "resume", "论文窗口")
  cross_identity_launch = File.readlines(launch_log, chomp: true).last
  unless cross_identity_launch == "unset|#{title_option} resume 论文窗口"
    raise "default identity did not resume the same named session"
  end
  run!(slot_environment, "launch", "--alias", "study", "--", "resume", "--all")
  explicit_picker_launch = File.readlines(launch_log, chomp: true).last
  unless explicit_picker_launch == "#{isolated_home}|#{title_option} resume --all"
    raise "explicit resume --all did not retain the native thread title"
  end
  forgotten = JSON.parse(run!(environment, "terminal-session", "forget", "--slot", "论文窗口", "--json"))
  raise "terminal slot was not forgotten" unless forgotten.fetch("removed")
  forgotten_status = JSON.parse(run!(environment, "terminal-session", "status", "--slot", "论文窗口", "--json"))
  raise "forgotten terminal slot remains bound" if forgotten_status.fetch("bound")

  run!(slot_environment, "launch", "--alias", "study", "--fresh")
  raise "slot --fresh did not start a titled new session" unless File.readlines(launch_log, chomp: true).last == "#{isolated_home}|#{title_option}"
  run!(launch_environment, "launch", "--alias", "study", "--fresh")
  raise "--fresh did not bypass session resume" unless File.readlines(launch_log, chomp: true).last == "#{isolated_home}|#{title_option}"
  run!(launch_environment, "launch", "--alias", "study", "--", "help me revise chapter 2")
  raise "initial prompt did not start an interactive titled session" unless File.readlines(launch_log, chomp: true).last == "#{isolated_home}|#{title_option} help me revise chapter 2"
  run!(launch_environment, "launch", "--alias", "study", "--", "app-server", "--stdio")
  raise "explicit Codex subcommand was rewritten as resume" unless File.readlines(launch_log, chomp: true).last == "#{isolated_home}|app-server --stdio"
  run!(launch_environment, "launch", "--alias", "study", "--resume", "--", "continue this")
  raise "explicit --resume did not resume the last titled session" unless File.readlines(launch_log, chomp: true).last == "#{isolated_home}|#{title_option} resume --last continue this"
  fail_run!(launch_environment.merge("CODEX_TEST_FAIL_RESUME" => "1"), "launch", "--alias", "study", "--resume")

  # A random shell-lifetime terminal instance owns only one exact native thread
  # UUID. The same terminal resumes it across identities; another terminal in the
  # same cwd starts fresh. The fake child holds native rollout filenames open so
  # the launcher can observe them without reading their contents.
  rollout_root = File.join(private_root, "conversation-pools", "main", "sessions", "2026", "08")
  FileUtils.mkdir_p(rollout_root)
  terminal_a = "123e4567-e89b-42d3-a456-426614174000"
  terminal_b = "223e4567-e89b-42d3-a456-426614174000"
  terminal_c = "323e4567-e89b-42d3-a456-426614174000"
  terminal_d = "423e4567-e89b-42d3-a456-426614174000"
  thread_u = "019d1234-5678-7abc-9def-0123456789ab"
  thread_v = "029d1234-5678-7abc-9def-0123456789ab"
  thread_w = "039d1234-5678-7abc-9def-0123456789ab"
  thread_x = "049d1234-5678-7abc-9def-0123456789ab"
  rollout = lambda do |thread_id|
    File.join(rollout_root, "rollout-2026-08-26T20-00-00-#{thread_id}.jsonl")
  end
  [thread_u, thread_v, thread_w, thread_x].each { |thread_id| File.write(rollout.call(thread_id), "do-not-read\n") }
  terminal_environment = lambda do |terminal_id, thread_id = nil|
    values = { "TWO_HEAD_WU_TERMINAL_INSTANCE_ID" => terminal_id }
    values["CODEX_TEST_ROLLOUT_PATH"] = rollout.call(thread_id) if thread_id
    launch_environment.merge(values)
  end

  run!(terminal_environment.call(terminal_a, thread_u), "launch", "--alias", "study")
  terminal_a_first = File.readlines(launch_log, chomp: true).last
  raise "unbound terminal did not start fresh" unless terminal_a_first == "#{isolated_home}|#{title_option}"

  continuation_path = File.join(private_root, "terminal-continuations.json")
  continuation = JSON.parse(File.read(continuation_path, encoding: "UTF-8"))
  terminal_a_key = Digest::SHA256.hexdigest(terminal_a)
  unless continuation.dig("instances", terminal_a_key, "session_id") == thread_u
    raise "fresh terminal session was not bound to its observed UUID"
  end
  raise "terminal continuation registry persisted the raw instance ID" if File.read(continuation_path).include?(terminal_a)
  if JSON.generate(continuation).match?(/token|password|email|auth\.json/i)
    raise "terminal continuation registry contains a forbidden secret-like field"
  end
  raise "terminal continuation registry mode is not 0600" unless (File.stat(continuation_path).mode & 0o777) == 0o600
  lock_path = File.join(private_root, "terminal-continuations.lock")
  raise "terminal continuation lock mode is not 0600" unless (File.stat(lock_path).mode & 0o777) == 0o600

  terminal_a_dry_run = run!(terminal_environment.call(terminal_a), "launch", "--alias", "member-two", "--dry-run")
  raise "bound terminal dry-run did not report exact continuation" unless terminal_a_dry_run.include?("launch_mode: terminal-resume")
  run!(terminal_environment.call(terminal_a, thread_u), "launch", "--alias", "member-two")
  terminal_a_switch = File.readlines(launch_log, chomp: true).last
  unless terminal_a_switch == "unset|#{title_option} resume #{thread_u}"
    raise "same terminal did not resume the exact UUID across identities"
  end
  thread_execution_path = File.join(private_root, "thread-executions.json")
  thread_execution = JSON.parse(File.read(thread_execution_path, encoding: "UTF-8"))
  unless thread_execution.dig("threads", thread_u, "identity") == "member-two"
    raise "thread did not record the latest explicitly selected identity"
  end
  unless thread_execution.dig("threads", thread_u, "conversation_pool") == "main"
    raise "thread execution record lost its conversation pool"
  end
  raise "thread execution registry mode is not 0600" unless (File.stat(thread_execution_path).mode & 0o777) == 0o600
  thread_execution_lock = File.join(private_root, "thread-executions.lock")
  raise "thread execution lock mode is not 0600" unless (File.stat(thread_execution_lock).mode & 0o777) == 0o600

  run!(terminal_environment.call(terminal_b, thread_v), "launch", "--alias", "member-two")
  terminal_b_first = File.readlines(launch_log, chomp: true).last
  raise "new terminal inferred an existing project session" unless terminal_b_first == "unset|#{title_option}"

  run!(terminal_environment.call(terminal_a, thread_v), "launch", "--alias", "study", "--fresh")
  terminal_a_fresh = File.readlines(launch_log, chomp: true).last
  raise "--fresh did not replace the terminal session" unless terminal_a_fresh == "#{isolated_home}|#{title_option}"
  run!(terminal_environment.call(terminal_a, thread_v), "launch", "--alias", "member-two")
  unless File.readlines(launch_log, chomp: true).last == "unset|#{title_option} resume #{thread_v}"
    raise "bare launch did not resume the replacement session"
  end

  run!(terminal_environment.call(terminal_a, thread_w), "launch", "--alias", "study", "--", "start another task")
  unless File.readlines(launch_log, chomp: true).last == "#{isolated_home}|#{title_option} start another task"
    raise "initial prompt did not explicitly start a new session"
  end
  run!(terminal_environment.call(terminal_a), "launch", "--alias", "study", "--", "exec", "printf ok")
  raise "non-interactive command was rewritten" unless File.readlines(launch_log, chomp: true).last == "#{isolated_home}|exec printf ok"
  run!(terminal_environment.call(terminal_a), "launch", "--alias", "study", "--", "-s", "read-only", "review", "--help")
  unless File.readlines(launch_log, chomp: true).last == "#{isolated_home}|-s read-only review --help"
    raise "option-prefixed non-interactive command was rewritten"
  end
  run!(terminal_environment.call(terminal_a, thread_w), "launch", "--alias", "member-two")
  unless File.readlines(launch_log, chomp: true).last == "unset|#{title_option} resume #{thread_w}"
    raise "non-interactive command changed the terminal continuation"
  end
  run!(terminal_environment.call(terminal_a, thread_w), "launch", "--alias", "study", "--", "-s", "read-only")
  unless File.readlines(launch_log, chomp: true).last == "#{isolated_home}|#{title_option} resume #{thread_w} -s read-only"
    raise "global interactive options did not preserve the terminal continuation"
  end
  run!(terminal_environment.call(terminal_d, thread_x), "launch", "--alias", "study", "--", "--no-alt-screen")
  unless File.readlines(launch_log, chomp: true).last == "#{isolated_home}|#{title_option} --no-alt-screen"
    raise "global interactive options inferred a session in a new terminal"
  end

  _output, _error, failed_resume = Open3.capture3(
    terminal_environment.call(terminal_a).merge("CODEX_TEST_FAIL_RESUME" => "1"),
    ADAPTER.to_s, "launch", "--alias", "study", "--", "-s", "read-only", "resume", "missing-name"
  )
  raise "explicit resume did not preserve the native failure status" unless failed_resume.exitstatus == 7
  run!(terminal_environment.call(terminal_a, thread_w), "launch", "--alias", "member-two")
  unless File.readlines(launch_log, chomp: true).last == "unset|#{title_option} resume #{thread_w}"
    raise "failed explicit resume discarded the terminal continuation"
  end

  run!(terminal_environment.call(terminal_b, thread_u), "launch", "--alias", "study", "--", "resume", "论文窗口")
  unless File.readlines(launch_log, chomp: true).last == "#{isolated_home}|#{title_option} resume 论文窗口"
    raise "explicit named resume was rewritten"
  end
  run!(terminal_environment.call(terminal_b, thread_u), "launch", "--alias", "member-two")
  unless File.readlines(launch_log, chomp: true).last == "unset|#{title_option} resume #{thread_u}"
    raise "explicit named resume did not become the terminal continuation"
  end
  run!(terminal_environment.call(terminal_b), "launch", "--alias", "study", "--", "-s", "read-only", "resume", "unobserved-name")
  continuation = JSON.parse(File.read(continuation_path, encoding: "UTF-8"))
  if continuation.fetch("instances").key?(Digest::SHA256.hexdigest(terminal_b))
    raise "successful unobserved explicit resume retained a stale terminal continuation"
  end
  run!(terminal_environment.call(terminal_b, thread_v), "launch", "--alias", "study")
  unless File.readlines(launch_log, chomp: true).last == "#{isolated_home}|#{title_option}"
    raise "terminal with an unobserved explicit resume did not return to fresh behavior"
  end

  ambiguous = terminal_environment.call(terminal_c, thread_u).merge("CODEX_TEST_SECOND_ROLLOUT_PATH" => rollout.call(thread_x))
  run!(ambiguous, "launch", "--alias", "study")
  continuation = JSON.parse(File.read(continuation_path, encoding: "UTF-8"))
  if continuation.fetch("instances").key?(Digest::SHA256.hexdigest(terminal_c))
    raise "ambiguous rollout observation guessed a terminal session"
  end
  fail_run!(launch_environment.merge("TWO_HEAD_WU_TERMINAL_INSTANCE_ID" => "not-a-uuid"), "launch", "--alias", "study", "--dry-run")
  fail_run!(launch_environment, "launch", "--alias", "study", "--fresh", "--resume")
  fail_run!(launch_environment, "launch", "--alias", "study", "--fresh", "--", "resume", thread_u)
  fail_run!(environment, "bind", "--project", "personal", "--alias", "member-two")
  fail_run!(environment, "add", "--alias", "UPPERCASE")

  fail_run!(environment, "remove", "--alias", "study", "--yes")
  run!(environment, "unbind", "--project", "thesis")
  run!(environment, "unbind", "--project", "two-head-wu")
  remove_preview = JSON.parse(run!(environment, "remove", "--alias", "study", "--json"))
  raise "remove without --yes should only preview" unless remove_preview.fetch("result") == "remove-preview"
  raise "preview must not delete the identity" unless JSON.parse(run!(environment, "status", "--json")).fetch("identities").any? { |item| item.fetch("id") == "study" }
  raise "isolated home should still exist after preview" unless File.directory?(isolated_home)
  remove_result = JSON.parse(run!(environment, "remove", "--alias", "study", "--yes", "--json"))
  raise "remove did not report success" unless remove_result.fetch("result") == "removed"
  raise "removed identity still present" if JSON.parse(run!(environment, "status", "--json")).fetch("identities").any? { |item| item.fetch("id") == "study" }
  raise "removed identity's isolated home was not deleted" if File.directory?(isolated_home)
  pool_status_after_remove = JSON.parse(run!(environment, "pool-status", "--json")).fetch("pools").find { |item| item.fetch("id") == "main" }
  raise "removed identity was not dropped from its conversation pool" if pool_status_after_remove.fetch("identities").include?("study")
  route_status_after_remove = JSON.parse(run!(environment, "route-status", "--json"))
  raise "removed identity's channel route was not cleaned up" if route_status_after_remove.fetch("channel_routes").value?("study")
  fail_run!(environment, "remove", "--alias", "member-two", "--yes")

  # Replacing the native default is an explicit, two-stage operation. It keeps the
  # already-signed-in native ~/.codex root, removes the duplicate isolated root,
  # and rewrites metadata references without reading or copying credentials.
  run!(environment, "add", "--alias", "primary", "--mode", "project-auto")
  primary_home = File.join(private_root, "codex-homes", "primary")
  File.write(File.join(primary_home, "retired-state-marker"), "delete me\n")
  run!(environment, "bind", "--project", "primary-project", "--alias", "primary")
  run!(environment, "route-set", "--channel", "openclaw-weixin", "--session", "default-owner@example", "--alias", "member-two", "--json")
  fail_run!(environment, "make-default", "--alias", "member-two", "--yes")
  fail_run!(environment, "make-default", "--alias", "sat", "--yes")

  default_preview = JSON.parse(run!(environment, "make-default", "--alias", "primary", "--json"))
  raise "make-default without --yes should only preview" unless default_preview.fetch("result") == "make-default-preview"
  raise "make-default preview reported the wrong old default" unless default_preview.fetch("old_default") == "member-two"
  raise "make-default preview reported the wrong target" unless default_preview.fetch("new_default") == "primary"
  raise "make-default preview reported the wrong isolated home" unless default_preview.fetch("isolated_codex_home_to_delete") == primary_home
  raise "make-default preview changed the registry" unless JSON.parse(run!(environment, "home", "--alias", "member-two", "--json")).fetch("state_kind") == "default"
  raise "make-default preview deleted the isolated home" unless File.directory?(primary_home)

  default_result = JSON.parse(run!(environment, "make-default", "--alias", "primary", "--yes", "--json"))
  raise "make-default did not report success" unless default_result.fetch("result") == "default-updated"
  migrated_status = JSON.parse(run!(environment, "status", "--json"))
  raise "old default identity still exists" if migrated_status.fetch("identities").any? { |item| item.fetch("id") == "member-two" }
  primary_identity = migrated_status.fetch("identities").find { |item| item.fetch("id") == "primary" }
  raise "target identity was not promoted to default" unless primary_identity && primary_identity.fetch("state_kind") == "default"
  raise "retired isolated home was not deleted" if File.exist?(primary_home)
  raise "project binding did not survive default replacement" unless JSON.parse(run!(environment, "select", "--project", "primary-project", "--json")).fetch("identity") == "primary"
  migrated_route = JSON.parse(run!(environment, "route-select", "--channel", "openclaw-weixin", "--session", "default-owner@example", "--json"))
  raise "old default route was not migrated" unless migrated_route.fetch("identity") == "primary"
  migrated_pool = JSON.parse(run!(environment, "pool-status", "--json")).fetch("pools").find { |item| item.fetch("id") == "main" }
  raise "old default remained in the conversation pool" if migrated_pool.fetch("identities").include?("member-two")
  raise "new default disappeared from the conversation pool" unless migrated_pool.fetch("identities").include?("primary")
  promoted_home = JSON.parse(run!(environment, "home", "--alias", "primary", "--json"))
  raise "new default does not resolve to the native Codex home" unless promoted_home.fetch("codex_home") == historical_home
  promoted_launch = run!(environment, "launch", "--alias", "primary", "--dry-run")
  raise "new default launch is not reported as default" unless promoted_launch.include?("state_kind: default")
  fail_run!(environment, "remove", "--alias", "primary", "--yes")

  state_path = File.join(private_root, "identities.json")
  state = JSON.parse(File.read(state_path, encoding: "UTF-8"))
  raise "registry mode is not 0600" unless (File.stat(state_path).mode & 0o777) == 0o600
  serialized = JSON.generate(state)
  raise "registry contains a forbidden secret-like field" if serialized.match?(/token|password|email|auth\.json/i)
  source = File.read(ADAPTER, encoding: "UTF-8")
  raise "adapter must not name or inspect Codex auth files" if source.include?("auth.json")
end

Dir.mktmpdir("two-head-wu-air-worker-identities-") do |temporary|
  runtime_root = File.join(temporary, "runtime")
  identity_root = File.join(runtime_root, "agent-identity")
  fake_codex = File.join(temporary, "codex")
  login_log = File.join(temporary, "login.log")
  FileUtils.mkdir_p(runtime_root, mode: 0o700)
  File.write(fake_codex, <<~SH)
    #!/bin/sh
    printf '%s|%s\n' "${CODEX_HOME-unset}" "$*" > "$CODEX_TEST_LOGIN_LOG"
  SH
  File.chmod(0o755, fake_codex)
  environment = {
    "HOME" => runtime_root,
    "TWO_HEAD_WU_IDENTITY_ROOT" => identity_root,
    "WU_MEMBER_RUNTIME_ROOT" => runtime_root,
    "WU_MEMBER_RUNTIME_UID" => Process.euid.to_s,
    "WU_MEMBER_OWNER_UID" => (Process.euid + 1).to_s,
    "TWO_HEAD_WU_CODEX_BIN" => fake_codex,
    "TWO_HEAD_WU_CODEX_LOGIN_DEVICE_AUTH" => "1",
    "CODEX_TEST_LOGIN_LOG" => login_log
  }
  run!(environment, "init")
  added = JSON.parse(run!(environment, "add-member", "--alias", "owner-primary", "--json"))
  raise "dedicated Air Worker could not register the owner's fixed identity" unless added.fetch("identity") == "owner-primary"
  resolved = JSON.parse(run!(environment, "member-home", "--alias", "owner-primary", "--json"))
  raise "owner Air identity escaped the worker-only scope" unless resolved.fetch("usage_scope") == "member-remote-work"
  run!(environment, "login", "--alias", "owner-primary")
  unless File.read(login_log, encoding: "UTF-8").end_with?("|login --device-auth\n")
    raise "Air Worker login did not use the pinned Codex executable and device-code flow"
  end
end


Dir.mktmpdir("two-head-wu-shared-state-") do |temporary|
  home = File.join(temporary, "home")
  native_home = File.join(home, ".codex")
  private_root = File.join(temporary, "private", "agent-identity")
  environment = { "HOME" => home, "TWO_HEAD_WU_IDENTITY_ROOT" => private_root }
  FileUtils.mkdir_p(native_home, mode: 0o700)
  native_database = File.join(native_home, "state_5.sqlite")
  create_state_database(native_database, [
    { id: "native-only", rollout_path: File.join(native_home, "sessions", "native.jsonl"), title: "native", updated_at: 10 },
    { id: "shared-id", rollout_path: File.join(native_home, "sessions", "old.jsonl"), title: "old title", updated_at: 20 }
  ])

  run!(environment, "init")
  run!(environment, "register-current", "--alias", "native")
  run!(environment, "add", "--alias", "secondary")
  secondary_home = File.join(private_root, "codex-homes", "secondary")
  secondary_database = File.join(secondary_home, "state_5.sqlite")
  create_state_database(secondary_database, [
    { id: "secondary-only", rollout_path: File.join(secondary_home, "sessions", "secondary.jsonl"), title: "secondary", updated_at: 30 },
    { id: "shared-id", rollout_path: File.join(secondary_home, "sessions", "new.jsonl"), title: "new title", updated_at: 40 }
  ])

  preview = JSON.parse(run!(environment, "pool-state", "enable", "--pool", "main", "--json"))
  raise "shared-state enable did not default to preview" unless preview.fetch("result") == "pool-state-enable-preview"
  raise "shared-state preview selected the wrong base" unless preview.fetch("base_alias") == "native"
  raise "shared-state preview unexpectedly found blockers: #{preview.fetch('blockers')}" unless preview.fetch("blockers").empty?
  raise "shared-state preview changed a source database" if File.symlink?(native_database) || File.symlink?(secondary_database)

  enabled = JSON.parse(run!(environment, "pool-state", "enable", "--pool", "main", "--yes", "--json"))
  raise "shared-state enable did not report success" unless enabled.fetch("result") == "pool-state-enabled"
  raise "shared-state union lost a thread" unless enabled.fetch("thread_count") == 3
  shared_database = enabled.fetch("database")
  raise "native identity is not linked to shared state" unless File.symlink?(native_database) && File.realpath(native_database) == File.realpath(shared_database)
  raise "secondary identity is not linked to shared state" unless File.symlink?(secondary_database) && File.realpath(secondary_database) == File.realpath(shared_database)
  raise "shared state database mode is not 0600" unless (File.stat(shared_database).mode & 0o777) == 0o600

  titles, title_error, title_status = Open3.capture3("sqlite3", shared_database, "SELECT title FROM threads WHERE id='shared-id';")
  raise "could not read merged state: #{title_error}" unless title_status.success?
  raise "newer duplicate thread metadata did not win" unless titles.strip == "new title"
  paths, path_error, path_status = Open3.capture3("sqlite3", shared_database, "SELECT rollout_path FROM threads ORDER BY id;")
  raise "could not read normalized rollout paths: #{path_error}" unless path_status.success?
  pool_session_root = File.join(private_root, "conversation-pools", "main", "sessions")
  raise "merged rollout paths were not normalized into the pool" unless paths.lines.all? { |line| line.strip.start_with?("#{pool_session_root}/") }

  pool_state = JSON.parse(run!(environment, "pool-state", "status", "--pool", "main", "--json"))
  raise "shared state status is not enabled" unless pool_state.fetch("enabled") && pool_state.fetch("thread_count") == 3
  raise "shared state status did not report every link" unless pool_state.fetch("identities").all? { |identity| identity.fetch("linked") }
  pool_status = JSON.parse(run!(environment, "pool-status", "--json")).fetch("pools").find { |pool| pool.fetch("id") == "main" }
  raise "pool status omitted shared state" unless pool_status.dig("shared_state", "enabled")

  # A fresh identity has no independent catalog, so it can safely join an enabled
  # shared-state pool and immediately sees the same `resume --all` index.
  run!(environment, "add", "--alias", "late")
  late_home = File.join(private_root, "codex-homes", "late")
  late_database = File.join(private_root, "codex-homes", "late", "state_5.sqlite")
  raise "new identity did not inherit shared state" unless File.symlink?(late_database) && File.realpath(late_database) == File.realpath(shared_database)
  _bad_output, bad_error, bad_status = Open3.capture3("sqlite3", shared_database,
    "INSERT INTO threads(id, rollout_path, updated_at, updated_at_ms, title) VALUES('unsafe-home', '#{late_home}/sessions/unsafe.jsonl', 60, 60000, 'unsafe');")
  raise "could not create unsafe rollout fixture: #{bad_error}" unless bad_status.success?
  fail_run!(environment, "remove", "--alias", "late", "--yes")
  raise "unsafe shared rollout guard partially removed the identity home" unless File.directory?(late_home)
  _delete_output, delete_error, delete_status = Open3.capture3("sqlite3", shared_database, "DELETE FROM threads WHERE id='unsafe-home';")
  raise "could not clear unsafe rollout fixture: #{delete_error}" unless delete_status.success?

  # Existing independent state is never overwritten by a routine pool attach.
  run!(environment, "add", "--alias", "independent", "--no-pool")
  independent_home = File.join(private_root, "codex-homes", "independent")
  create_state_database(File.join(independent_home, "state_5.sqlite"), [
    { id: "independent", rollout_path: File.join(independent_home, "sessions", "independent.jsonl"), title: "independent", updated_at: 50 }
  ])
  fail_run!(environment, "pool-attach", "--pool", "main", "--alias", "independent")
  raise "failed attach partially linked independent sessions" if File.symlink?(File.join(independent_home, "sessions"))

  backup = enabled.fetch("backup")
  raise "migration backup manifest is missing" unless File.file?(File.join(backup, "manifest.json"))
  raise "migration backup manifest mode is not 0600" unless (File.stat(File.join(backup, "manifest.json")).mode & 0o777) == 0o600
end

Dir.mktmpdir("two-head-wu-project-terminal-") do |temporary|
  home = File.join(temporary, "home")
  native_home = File.join(home, ".codex")
  private_root = File.join(temporary, "private", "agent-identity")
  fake_bin = File.join(temporary, "bin")
  workspace = File.join(temporary, "workspace")
  FileUtils.mkdir_p(native_home, mode: 0o700)
  FileUtils.mkdir_p(fake_bin)
  FileUtils.mkdir_p(workspace)
  thread_id = "119d1234-5678-7abc-9def-0123456789ab"
  rollout = File.join(private_root, "conversation-pools", "main", "sessions", "2026", "09", "rollout-2026-09-02T18-00-00-#{thread_id}.jsonl")
  create_state_database(File.join(native_home, "state_5.sqlite"), [
    { id: thread_id, rollout_path: rollout, title: "system health", name: "两头乌-系统健康", cwd: workspace, updated_at: 70 }
  ])

  environment = {
    "HOME" => home,
    "TWO_HEAD_WU_IDENTITY_ROOT" => private_root,
    "TWO_HEAD_WU_TESTING" => "1"
  }
  run!(environment, "init")
  run!(environment, "register-current", "--alias", "owner", "--mode", "project-auto")
  run!(environment, "bind", "--project", "two-head-wu", "--alias", "owner")
  FileUtils.mkdir_p(File.dirname(rollout))
  File.write(rollout, "do-not-read\n")

  fake_codex = File.join(fake_bin, "codex")
  File.write(fake_codex, <<~SH)
    #!/bin/sh
    if [ -n "${TWO_HEAD_WU_TERMINAL_INSTANCE_ID-}" ] || [ -n "${TWO_HEAD_WU_PROJECT_TERMINAL_ID-}" ] || [ -n "${TWO_HEAD_WU_PROJECT_ID-}" ]; then
      exit 23
    fi
    printf '%s|%s\n' "${CODEX_HOME-unset}" "$*" >> "$CODEX_TEST_LOG"
    exec 8>> "$CODEX_TEST_ROLLOUT_PATH"
    sleep 0.4
    if [ -n "${CODEX_TEST_SIGNAL-}" ]; then
      kill -"$CODEX_TEST_SIGNAL" $$
    fi
    if [ -n "${CODEX_TEST_EXIT-}" ]; then
      exit "$CODEX_TEST_EXIT"
    fi
    exit 0
  SH
  File.chmod(0o755, fake_codex)
  launch_log = File.join(temporary, "project-terminal-launch.log")
  launch_environment = environment.merge(
    "PATH" => "#{fake_bin}:#{ENV.fetch('PATH', '')}",
    "CODEX_TEST_LOG" => launch_log,
    "CODEX_TEST_ROLLOUT_PATH" => rollout
  )

  allocated = JSON.parse(run!(environment, "project-terminal", "allocate", "--project", "two-head-wu", "--cwd", workspace, "--json"))
  terminal_id = allocated.fetch("terminal")
  raise "allocated project terminal is not a UUID" unless terminal_id.match?(/\A[0-9a-f-]{36}\z/)
  managed_environment = launch_environment.merge(
    "TWO_HEAD_WU_PROJECT_ID" => "two-head-wu",
    "TWO_HEAD_WU_PROJECT_TERMINAL_ID" => terminal_id,
    "TWO_HEAD_WU_TERMINAL_INSTANCE_ID" => terminal_id,
    "CODEX_TEST_SIGNAL" => "HUP"
  )
  _output, error, interrupted = Open3.capture3(managed_environment, ADAPTER.to_s, "project-terminal", "start", "--terminal", terminal_id, "--alias", "owner")
  raise "signaled managed terminal unexpectedly succeeded: #{error}" if interrupted.success?
  raise "signaled managed terminal did not preserve the signal exit" unless interrupted.exitstatus == 129

  recoverable = JSON.parse(run!(environment, "project-terminal", "status", "--terminal", terminal_id, "--json"))
  raise "interrupted managed terminal was not recoverable" unless recoverable.fetch("status") == "recoverable" && recoverable.fetch("auto_restore")
  raise "managed terminal lost its exact thread" unless recoverable.fetch("thread") == thread_id
  raise "managed terminal lost its last identity" unless recoverable.fetch("identity") == "owner"
  raise "managed terminal did not expose the native thread name" unless recoverable.fetch("name") == "两头乌-系统健康"

  run!(managed_environment.reject { |key, _value| key == "CODEX_TEST_SIGNAL" }, "project-terminal", "start", "--terminal", terminal_id, "--alias", "owner")
  restored_launch = File.readlines(launch_log, chomp: true).last
  unless restored_launch.include?("-C #{workspace}") && restored_launch.end_with?("resume #{thread_id}")
    raise "managed terminal did not restore the exact cwd and UUID: #{restored_launch}"
  end
  inactive = JSON.parse(run!(environment, "project-terminal", "status", "--terminal", terminal_id, "--json"))
  raise "normal Codex exit did not deactivate auto restore" unless inactive.fetch("status") == "inactive" && !inactive.fetch("auto_restore")

  adopted = JSON.parse(run!(environment, "project-terminal", "adopt", "--project", "two-head-wu", "--thread", thread_id, "--alias", "owner", "--cwd", workspace, "--json"))
  raise "explicit thread adoption was not recoverable" unless adopted.fetch("auto_restore") && adopted.fetch("thread") == thread_id
  adopted_environment = launch_environment.merge(
    "TWO_HEAD_WU_PROJECT_ID" => "two-head-wu",
    "TWO_HEAD_WU_PROJECT_TERMINAL_ID" => adopted.fetch("terminal"),
    "TWO_HEAD_WU_TERMINAL_INSTANCE_ID" => adopted.fetch("terminal")
  )
  run!(adopted_environment, "project-terminal", "restore", "--terminal", adopted.fetch("terminal"))
  close = JSON.parse(run!(environment, "project-terminal", "close", "--terminal", adopted.fetch("terminal"), "--reason", "user", "--json"))
  raise "user close did not suppress recovery" unless close.fetch("status") == "user-closed"

  blocked = JSON.parse(run!(environment, "project-terminal", "adopt", "--project", "two-head-wu", "--thread", thread_id, "--alias", "owner", "--cwd", workspace, "--json"))
  blocked_environment = launch_environment.merge(
    "TWO_HEAD_WU_PROJECT_ID" => "two-head-wu",
    "TWO_HEAD_WU_PROJECT_TERMINAL_ID" => blocked.fetch("terminal"),
    "TWO_HEAD_WU_TERMINAL_INSTANCE_ID" => blocked.fetch("terminal"),
    "CODEX_TEST_EXIT" => "7"
  )
  _blocked_output, _blocked_error, blocked_status = Open3.capture3(
    blocked_environment,
    ADAPTER.to_s,
    "project-terminal", "restore", "--terminal", blocked.fetch("terminal")
  )
  raise "failed managed restore unexpectedly succeeded" if blocked_status.success?
  blocked_state = JSON.parse(run!(environment, "project-terminal", "status", "--terminal", blocked.fetch("terminal"), "--json"))
  unless blocked_state.fetch("status") == "blocked" && blocked_state.fetch("last_exit_code") == 7 && !blocked_state.fetch("auto_restore")
    raise "failed managed restore did not enter a diagnostic blocked state"
  end
  listing = JSON.parse(run!(environment, "project-terminal", "list", "--project", "two-head-wu", "--json"))
  raise "inactive or user-closed terminal leaked into restore list" unless listing.fetch("restore").empty?

  registry_path = File.join(private_root, "project-terminals.json")
  raise "project terminal registry mode is not 0600" unless (File.stat(registry_path).mode & 0o777) == 0o600
  serialized = File.read(registry_path, encoding: "UTF-8")
  raise "project terminal registry contains forbidden content" if serialized.match?(/token|password|email|auth\.json|do-not-read/i)
  fail_run!(environment, "project-terminal", "adopt", "--project", "two-head-wu", "--thread", "219d1234-5678-7abc-9def-0123456789ab", "--alias", "owner", "--cwd", workspace)
end

Dir.mktmpdir("two-head-wu-owner-auto-") do |temporary|
  home = File.join(temporary, "home")
  private_root = File.join(temporary, "private", "agent-identity")
  fake_bin = File.join(temporary, "bin")
  FileUtils.mkdir_p(File.join(home, ".codex"), mode: 0o700)
  FileUtils.mkdir_p(fake_bin)
  fake_codex = File.join(fake_bin, "codex")
  File.write(fake_codex, <<~'RUBY')
    #!/usr/bin/env ruby
    require "json"

    exit 0 unless ARGV == ["app-server", "--stdio"]
    home = ENV["CODEX_HOME"].to_s
    key = home.empty? ? "CODEX_TEST_DEFAULT_USED" : "CODEX_TEST_WMM_USED"
    exit 9 if ENV["CODEX_TEST_FAIL"] == (home.empty? ? "owner-primary" : "owner-secondary")
    used = Float(ENV.fetch(key, "0"))
    while (line = STDIN.gets)
      message = JSON.parse(line)
      next unless message["id"]
      result = case message["method"]
               when "initialize" then {}
               when "account/read" then { "account" => { "type" => "chatgpt" } }
               when "account/rateLimits/read"
                 {
                   "rateLimits" => {
                     "limitId" => "codex",
                     "primary" => { "usedPercent" => used, "resetsAt" => 1_900_000_000 }
                   }
                 }
               else {}
               end
      puts JSON.generate("id" => message["id"], "result" => result)
      STDOUT.flush
    end
  RUBY
  File.chmod(0o755, fake_codex)
  environment = {
    "HOME" => home,
    "CODEX_HOME" => nil,
    "TWO_HEAD_WU_IDENTITY_ROOT" => private_root,
    "PATH" => "#{fake_bin}:#{ENV.fetch('PATH', '')}"
  }

  run!(environment, "init")
  run!(environment, "register-current", "--alias", "owner-primary", "--mode", "project-auto")
  run!(environment, "add", "--alias", "owner-secondary", "--mode", "manual")
  run!(environment, "add", "--alias", "classmate", "--mode", "manual")
  run!(environment, "bind", "--project", "two-head-wu", "--alias", "owner-primary")
  disabled = JSON.parse(run!(environment, "owner-auto", "status", "--json"))
  raise "owner auto should be disabled before explicit configuration" if disabled.dig("owner_auto", "enabled")
  enabled = JSON.parse(run!(environment, "owner-auto", "enable", "--json"))
  unless enabled.fetch("owner_auto") == {
    "enabled" => true,
    "members" => %w[owner-primary owner-secondary],
    "channels" => %w[remote-work openclaw-weixin]
  }
    raise "owner auto policy did not use the fixed owner-only boundary"
  end
  fail_run!(environment, "remove", "--alias", "owner-secondary", "--yes")
  raise "guarded owner identity removal deleted its home" unless File.directory?(File.join(private_root, "codex-homes", "owner-secondary"))
  fail_run!(environment, "make-default", "--alias", "owner-secondary", "--yes")

  available_environment = environment.merge("CODEX_TEST_DEFAULT_USED" => "40", "CODEX_TEST_WMM_USED" => "0")
  primary = JSON.parse(run!(available_environment, "route-select", "--channel", "remote-work", "--session", "owner-queue", "--json"))
  raise "available primary owner identity was not selected" unless primary.fetch("identity") == "owner-primary"
  raise "owner auto selection source drift" unless primary.fetch("source") == "owner-auto" && primary.fetch("quota_probe") == "available"

  fallback_environment = environment.merge("CODEX_TEST_DEFAULT_USED" => "100", "CODEX_TEST_WMM_USED" => "10")
  fallback = JSON.parse(run!(fallback_environment, "route-select", "--channel", "remote-work", "--session", "owner-queue", "--json"))
  raise "exhausted primary owner identity did not fail over" unless fallback.fetch("identity") == "owner-secondary"
  raise "quota failover reason drift" unless fallback.fetch("selection_reason") == "quota-failover"

  run!(environment, "route-set", "--channel", "openclaw-weixin", "--session", "owner@example", "--alias", "owner-secondary", "--json")
  routed_fallback = JSON.parse(run!(
    environment.merge("CODEX_TEST_DEFAULT_USED" => "5", "CODEX_TEST_WMM_USED" => "100"),
    "route-select", "--channel", "openclaw-weixin", "--session", "owner@example", "--json"
  ))
  raise "owner route did not use the owner automatic pool" unless routed_fallback.fetch("identity") == "owner-primary"
  raise "owner route source drift" unless routed_fallback.fetch("source") == "owner-auto-route"

  run!(environment, "route-set", "--channel", "openclaw-weixin", "--session", "friend@example", "--alias", "classmate", "--json")
  manual = JSON.parse(run!(
    environment.merge("CODEX_TEST_DEFAULT_USED" => "100", "CODEX_TEST_WMM_USED" => "100", "CODEX_TEST_FAIL" => "owner-primary"),
    "route-select", "--channel", "openclaw-weixin", "--session", "friend@example", "--json"
  ))
  raise "non-owner route was not pinned manually" unless manual.fetch("identity") == "classmate" && manual.fetch("source") == "channel-route"

  unknown = JSON.parse(run!(
    environment.merge("CODEX_TEST_DEFAULT_USED" => "0", "CODEX_TEST_WMM_USED" => "0", "CODEX_TEST_FAIL" => "owner-primary"),
    "route-select", "--channel", "remote-work", "--session", "owner-queue", "--json"
  ))
  raise "generic probe failure silently switched identities" unless unknown.fetch("identity") == "owner-primary" && unknown.fetch("quota_probe") == "unknown"

  fail_run!(
    environment.merge("CODEX_TEST_DEFAULT_USED" => "100", "CODEX_TEST_WMM_USED" => "100"),
    "route-select", "--channel", "remote-work", "--session", "owner-queue", "--json"
  )
end

Dir.mktmpdir("two-head-wu-scheduled-continuation-") do |temporary|
  home = File.join(temporary, "home")
  private_root = File.join(temporary, "private", "agent-identity")
  fake_bin = File.join(temporary, "bin")
  command_log = File.join(temporary, "codex-commands.jsonl")
  cron_log = File.join(temporary, "openclaw-cron.jsonl")
  FileUtils.mkdir_p(File.join(home, ".codex"), mode: 0o700)
  FileUtils.mkdir_p(fake_bin)

  fake_codex = File.join(fake_bin, "codex")
  File.write(fake_codex, <<~'RUBY')
    #!/usr/bin/env ruby
    require "json"

    if ARGV == ["app-server", "--stdio"]
      while (line = STDIN.gets)
        message = JSON.parse(line)
        next unless message["id"]
        result = case message["method"]
                 when "initialize" then {}
                 when "account/read" then { "account" => { "type" => "chatgpt" } }
                 when "account/rateLimits/read"
                   {
                     "rateLimits" => {
                       "limitId" => "codex",
                       "primary" => {
                         "usedPercent" => Float(ENV.fetch("CODEX_TEST_PRIMARY_USED", "0")),
                         "resetsAt" => Integer(ENV.fetch("CODEX_TEST_PRIMARY_RESET", "0"))
                       },
                       "secondary" => {
                         "usedPercent" => Float(ENV.fetch("CODEX_TEST_SECONDARY_USED", "0")),
                         "resetsAt" => Integer(ENV.fetch("CODEX_TEST_SECONDARY_RESET", "0"))
                       }
                     }
                   }
                 when "thread/read"
                   turns = []
                   stored_turn = if ENV["CODEX_TEST_TURN_STATE_FILE"] && File.exist?(ENV.fetch("CODEX_TEST_TURN_STATE_FILE"))
                                   JSON.parse(File.read(ENV.fetch("CODEX_TEST_TURN_STATE_FILE")))
                                 else
                                   {}
                                 end
                   turn_id = stored_turn["id"] || ENV["CODEX_TEST_LATEST_TURN_ID"]
                   if turn_id && !turn_id.empty?
                     turns << {
                       "id" => turn_id,
                       "status" => stored_turn["status"] || ENV.fetch("CODEX_TEST_LATEST_TURN_STATUS", "completed"),
                       "items" => []
                     }
                   end
                   {
                     "thread" => {
                       "id" => message.dig("params", "threadId"),
                       "status" => { "type" => "notLoaded" },
                       "turns" => turns
                     }
                   }
                 else {}
                 end
        puts JSON.generate("id" => message["id"], "result" => result)
        STDOUT.flush
      end
      exit 0
    end

    File.open(ENV.fetch("CODEX_TEST_COMMAND_LOG"), "a") do |file|
      file.puts JSON.generate("argv" => ARGV, "codex_home" => ENV["CODEX_HOME"])
    end
    exit 8 if ARGV.first == "queue" && ENV["CODEX_TEST_QUEUE_FAIL"] == "1"
    if ARGV.first == "exec" && ENV["CODEX_TEST_AFTER_EXEC_TURN_STATUS"] && ENV["CODEX_TEST_TURN_STATE_FILE"]
      File.write(
        ENV.fetch("CODEX_TEST_TURN_STATE_FILE"),
        JSON.generate(
          "id" => ENV.fetch("CODEX_TEST_AFTER_EXEC_TURN_ID", ENV.fetch("CODEX_TEST_LATEST_TURN_ID")),
          "status" => ENV.fetch("CODEX_TEST_AFTER_EXEC_TURN_STATUS")
        )
      )
    end
    exit 0
  RUBY
  File.chmod(0o755, fake_codex)

  fake_openclaw = File.join(fake_bin, "openclaw")
  File.write(fake_openclaw, <<~'RUBY')
    #!/usr/bin/env ruby
    require "json"
    File.open(ENV.fetch("CODEX_TEST_CRON_LOG"), "a") { |file| file.puts JSON.generate(ARGV) }
    puts JSON.generate("id" => "job-test-123")
  RUBY
  File.chmod(0o755, fake_openclaw)
  helper = File.join(fake_bin, "codex-continue")
  File.symlink(ADAPTER.to_s, helper)

  environment = {
    "HOME" => home,
    "CODEX_HOME" => nil,
    "TWO_HEAD_WU_IDENTITY_ROOT" => private_root,
    "TWO_HEAD_WU_CODEX_BIN" => fake_codex,
    "TWO_HEAD_WU_OPENCLAW_BIN" => fake_openclaw,
    "TWO_HEAD_WU_TESTING" => "1",
    "TWO_HEAD_WU_TEST_NOW" => "2026-08-27T10:00:00+02:00",
    "CODEX_TEST_COMMAND_LOG" => command_log,
    "CODEX_TEST_CRON_LOG" => cron_log,
    "CODEX_TEST_TURN_STATE_FILE" => File.join(temporary, "turn-state.json"),
    "TZ" => "Europe/Rome",
    "PATH" => "#{fake_bin}:#{ENV.fetch('PATH', '')}",
    "CODEX_THREAD_ID" => "11111111-2222-4333-8444-555555555555",
    "CODEX_TEST_LATEST_TURN_ID" => "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
    "CODEX_TEST_LATEST_TURN_STATUS" => "inProgress"
  }
  run!(environment, "init")
  run!(environment, "register-current", "--alias", "awake")
  run!(environment, "add", "--alias", "sleeper")
  run!(environment, "add", "--alias", "runner")

  primary_reset = Time.iso8601("2026-08-27T11:00:00+02:00").to_i
  secondary_reset = Time.iso8601("2026-08-27T13:00:00+02:00").to_i
  quota_environment = environment.merge(
    "CODEX_TEST_PRIMARY_USED" => "100",
    "CODEX_TEST_PRIMARY_RESET" => primary_reset.to_s,
    "CODEX_TEST_SECONDARY_USED" => "100",
    "CODEX_TEST_SECONDARY_RESET" => secondary_reset.to_s
  )
  automatic = JSON.parse(run!(quota_environment, "continue-schedule", "--json"))
  raise "automatic continuation selected the wrong identity" unless automatic.fetch("identity") == "awake"
  raise "automatic continuation did not use quota insurance" unless automatic.fetch("source") == "quota-insurance"
  raise "automatic continuation did not wait for the last blocking reset plus three minutes" unless automatic.fetch("run_at") == "2026-08-27T13:03:00+02:00"
  raise "automatic continuation did not expose the OpenClaw job id" unless automatic.fetch("job_id") == "job-test-123"
  raise "automatic continuation is not thread-scoped" unless automatic.fetch("task_scope") == "thread"
  raise "automatic continuation treated the account as task owner" unless automatic.fetch("identity_role") == "execution-fallback"
  raise "automatic continuation did not expose its conditional guard" unless automatic.fetch("condition") == "continue-if-thread-task-remains-incomplete"

  cron_arguments = JSON.parse(File.readlines(cron_log, chomp: true).last)
  command_argv = JSON.parse(cron_arguments.fetch(cron_arguments.index("--command-argv") + 1))
  raise "cron payload did not use the internal continuation runner" unless command_argv[0, 2] == [ADAPTER.to_s, "continue-run"]
  raise "cron payload did not preserve the exact thread" unless command_argv.each_cons(2).any? { |left, right| left == "--thread" && right == environment.fetch("CODEX_THREAD_ID") }
  raise "cron payload did not preserve the turn guard" unless command_argv.each_cons(2).any? { |left, right| left == "--guard-turn" && right == environment.fetch("CODEX_TEST_LATEST_TURN_ID") }
  raise "cron payload did not preserve the guard status" unless command_argv.each_cons(2).any? { |left, right| left == "--guard-status" && right == "inProgress" }
  raise "cron payload did not preserve the task conversation pool" unless command_argv.each_cons(2).any? { |left, right| left == "--pool" && right == "main" }
  raise "cron task did not preserve the private registry root" unless cron_arguments.each_cons(2).any? { |left, right| left == "--command-env" && right == "TWO_HEAD_WU_IDENTITY_ROOT=#{private_root}" }
  raise "cron task was not one-shot" unless cron_arguments.include?("--delete-after-run")
  raise "cron task unexpectedly enables delivery" unless cron_arguments.include?("--no-deliver")

  continuous = JSON.parse(run!(quota_environment, "continue-schedule", "--until-complete", "--json"))
  raise "continuous insurance did not report its mode" unless continuous.fetch("mode") == "until-complete"
  raise "continuous insurance exposed the wrong condition" unless continuous.fetch("condition") == "continue-until-thread-task-completes"
  continuous_cron_arguments = JSON.parse(File.readlines(cron_log, chomp: true).last)
  continuous_command_argv = JSON.parse(continuous_cron_arguments.fetch(continuous_cron_arguments.index("--command-argv") + 1))
  raise "continuous flag was not persisted in the command argv" unless continuous_command_argv.include?("--until-complete")
  raise "continuous cron does not use an idempotent cycle declaration" unless continuous_cron_arguments.include?("--declaration-key")
  raise "continuous cron stopped being one-shot" unless continuous_cron_arguments.include?("--delete-after-run")
  fail_run!(quota_environment, "continue-schedule", "12:00", "--until-complete", "--dry-run")
  fail_run!(quota_environment.merge("CODEX_TEST_LATEST_TURN_ID" => nil), "continue-schedule", "--until-complete", "--dry-run")

  helper_output, helper_error, helper_status = Open3.capture3(environment, helper, "12:00", "检查测试并继续", "--dry-run", "--json")
  raise "codex-continue helper failed: #{helper_error}" unless helper_status.success?
  helper_preview = JSON.parse(helper_output)
  raise "helper did not select the next local clock time" unless helper_preview.fetch("run_at") == "2026-08-27T12:00:00+02:00"
  raise "helper changed the custom message" unless helper_preview.fetch("message_length") == "检查测试并继续".length

  shorthand_output, shorthand_error, shorthand_status = Open3.capture3(
    quota_environment,
    helper, "检查测试并继续", "--dry-run", "--json"
  )
  raise "message-only shorthand failed: #{shorthand_error}" unless shorthand_status.success?
  shorthand = JSON.parse(shorthand_output)
  raise "message-only shorthand stopped using quota insurance" unless shorthand.fetch("source") == "quota-insurance"
  raise "message-only shorthand changed the custom message" unless shorthand.fetch("message_length") == "检查测试并继续".length
  raise "message-only shorthand selected the wrong reset time" unless shorthand.fetch("run_at") == "2026-08-27T13:03:00+02:00"

  tomorrow = JSON.parse(run!(environment, "continue-schedule", "09:30", "--dry-run", "--json"))
  raise "past local time did not roll to tomorrow" unless tomorrow.fetch("run_at") == "2026-08-28T09:30:00+02:00"
  available = JSON.parse(run!(environment.merge(
    "CODEX_TEST_PRIMARY_USED" => "20",
    "CODEX_TEST_PRIMARY_RESET" => primary_reset.to_s,
    "CODEX_TEST_SECONDARY_USED" => "30",
    "CODEX_TEST_SECONDARY_RESET" => secondary_reset.to_s
  ), "continue-schedule", "--dry-run", "--json"))
  raise "available quota could not pre-register insurance" unless available.fetch("run_at") == "2026-08-27T11:03:00+02:00"
  fail_run!(environment.merge("CODEX_THREAD_ID" => nil), "continue-schedule", "12:00", "--dry-run")

  run_options = [
    "continue-run", "--alias", "sleeper",
    "--thread", environment.fetch("CODEX_THREAD_ID"),
    "--cwd", temporary,
    "--message", "继续",
    "--codex-bin", fake_codex,
    "--json"
  ]
  queued = JSON.parse(run!(environment, *run_options))
  raise "online session was not queued" unless queued.fetch("result") == "continue-queued"
  raise "scheduled thread did not prefer its latest explicit identity" unless queued.fetch("identity") == "awake" && queued.fetch("identity_source") == "thread-latest"
  queue_call = JSON.parse(File.readlines(command_log, chomp: true).last)
  unless queue_call.fetch("argv") == ["queue", "-C", temporary, "--thread", environment.fetch("CODEX_THREAD_ID"), "--message", "继续"]
    raise "queue call did not preserve exact cwd/thread/message"
  end
  raise "queue call did not use the latest explicit default identity" unless queue_call.fetch("codex_home").nil?

  # A thread task survives account replacement. Simulate the same thread being
  # explicitly opened with runner after registration; the cron's sleeper alias is
  # only a fallback and must not own or redirect the task.
  thread_execution_path = File.join(private_root, "thread-executions.json")
  thread_execution = JSON.parse(File.read(thread_execution_path, encoding: "UTF-8"))
  thread_execution.fetch("threads").fetch(environment.fetch("CODEX_THREAD_ID"))["identity"] = "runner"
  thread_execution.fetch("threads").fetch(environment.fetch("CODEX_THREAD_ID"))["updated_at"] = Time.now.utc.iso8601
  File.write(thread_execution_path, JSON.pretty_generate(thread_execution) + "\n")
  File.chmod(0o600, thread_execution_path)
  switched = JSON.parse(run!(environment, *run_options))
  raise "thread task stayed bound to the scheduled account" unless switched.fetch("identity") == "runner"
  switched_call = JSON.parse(File.readlines(command_log, chomp: true).last)
  expected_runner_home = File.join(private_root, "codex-homes", "runner")
  raise "cross-account continuation used the wrong identity home" unless switched_call.fetch("codex_home") == expected_runner_home

  guarded_options = run_options[0...-1] + [
    "--guard-turn", environment.fetch("CODEX_TEST_LATEST_TURN_ID"),
    "--guard-status", environment.fetch("CODEX_TEST_LATEST_TURN_STATUS"),
    "--json"
  ]
  command_count = File.readlines(command_log, chomp: true).length
  unchanged = JSON.parse(run!(environment, *guarded_options))
  raise "unchanged task marker was not skipped" unless unchanged.fetch("result") == "continue-skipped-unchanged"
  raise "unchanged task marker sent a duplicate" unless File.readlines(command_log, chomp: true).length == command_count

  completed = JSON.parse(run!(environment.merge(
    "CODEX_TEST_LATEST_TURN_ID" => "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff",
    "CODEX_TEST_LATEST_TURN_STATUS" => "completed"
  ), *guarded_options))
  raise "completed task was not skipped" unless completed.fetch("result") == "continue-skipped-completed"
  raise "completed task sent a duplicate" unless File.readlines(command_log, chomp: true).length == command_count

  active = JSON.parse(run!(environment.merge(
    "CODEX_TEST_LATEST_TURN_ID" => "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff",
    "CODEX_TEST_LATEST_TURN_STATUS" => "inProgress"
  ), *guarded_options))
  raise "active task was not skipped" unless active.fetch("result") == "continue-skipped-active"
  raise "active task sent a duplicate" unless File.readlines(command_log, chomp: true).length == command_count

  incomplete = JSON.parse(run!(environment.merge(
    "CODEX_TEST_LATEST_TURN_ID" => "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff",
    "CODEX_TEST_LATEST_TURN_STATUS" => "failed"
  ), *guarded_options))
  raise "failed task was not continued" unless incomplete.fetch("result") == "continue-queued"
  raise "failed task did not send exactly one continuation" unless File.readlines(command_log, chomp: true).length == command_count + 1

  interrupted_guard_options = run_options[0...-1] + [
    "--guard-turn", environment.fetch("CODEX_TEST_LATEST_TURN_ID"),
    "--guard-status", "interrupted",
    "--json"
  ]
  commands_before_false_completion = File.readlines(command_log, chomp: true).length
  false_completion = JSON.parse(run!(environment.merge(
    "CODEX_TEST_LATEST_TURN_STATUS" => "completed"
  ), *interrupted_guard_options))
  raise "same interrupted turn was falsely treated as completed" unless false_completion.fetch("result") == "continue-queued"
  raise "same interrupted turn did not receive one continuation" unless File.readlines(command_log, chomp: true).length == commands_before_false_completion + 1

  newer_completion = JSON.parse(run!(environment.merge(
    "CODEX_TEST_LATEST_TURN_ID" => "dddddddd-eeee-4fff-8aaa-bbbbbbbbbbbb",
    "CODEX_TEST_LATEST_TURN_STATUS" => "completed"
  ), *interrupted_guard_options))
  raise "newer completed turn did not stop the task" unless newer_completion.fetch("result") == "continue-skipped-completed"

  fail_run!(environment.merge(
    "CODEX_TEST_LATEST_TURN_ID" => "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff",
    "CODEX_TEST_LATEST_TURN_STATUS" => "mystery"
  ), *guarded_options)

  resumed = JSON.parse(run!(environment.merge("CODEX_TEST_QUEUE_FAIL" => "1"), *run_options))
  raise "failed queue did not fall back to resume" unless resumed.fetch("result") == "continue-resumed"
  calls = File.readlines(command_log, chomp: true).last(2).map { |line| JSON.parse(line) }
  raise "fallback did not try queue first" unless calls[0].fetch("argv").first == "queue"
  unless calls[1].fetch("argv") == ["exec", "-C", temporary, "resume", environment.fetch("CODEX_THREAD_ID"), "继续"]
    raise "fallback did not resume the exact thread"
  end

  next_reset = Time.iso8601("2026-08-27T14:00:00+02:00").to_i
  later_reset = Time.iso8601("2026-08-27T20:00:00+02:00").to_i
  continuous_cycle_environment = environment.merge(
    "TWO_HEAD_WU_TEST_NOW" => "2026-08-27T13:03:00+02:00",
    "CODEX_TEST_PRIMARY_USED" => "20",
    "CODEX_TEST_PRIMARY_RESET" => next_reset.to_s,
    "CODEX_TEST_SECONDARY_USED" => "30",
    "CODEX_TEST_SECONDARY_RESET" => later_reset.to_s
  )
  continuous_options = guarded_options[0...-1] + ["--until-complete", "--json"]

  continuous_command_count = File.readlines(command_log, chomp: true).length
  continuous_cron_count = File.readlines(cron_log, chomp: true).length
  rearmed_unchanged = JSON.parse(run!(continuous_cycle_environment, *continuous_options))
  raise "continuous unchanged turn did not re-arm" unless rearmed_unchanged.fetch("result") == "continue-rearmed-unchanged"
  raise "continuous unchanged turn selected the wrong next reset" unless rearmed_unchanged.fetch("run_at") == "2026-08-27T14:03:00+02:00"
  raise "continuous unchanged turn sent a duplicate" unless File.readlines(command_log, chomp: true).length == continuous_command_count
  raise "continuous unchanged turn did not register one next cycle" unless File.readlines(cron_log, chomp: true).length == continuous_cron_count + 1

  rearmed_active = JSON.parse(run!(continuous_cycle_environment.merge(
    "CODEX_TEST_LATEST_TURN_ID" => "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff",
    "CODEX_TEST_LATEST_TURN_STATUS" => "inProgress"
  ), *continuous_options))
  raise "continuous active turn did not re-arm" unless rearmed_active.fetch("result") == "continue-rearmed-active"
  raise "continuous active turn sent a duplicate" unless File.readlines(command_log, chomp: true).length == continuous_command_count

  cron_before_completed = File.readlines(cron_log, chomp: true).length
  continuous_completed = JSON.parse(run!(continuous_cycle_environment.merge(
    "CODEX_TEST_LATEST_TURN_ID" => "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff",
    "CODEX_TEST_LATEST_TURN_STATUS" => "completed"
  ), *continuous_options))
  raise "continuous completed turn did not stop" unless continuous_completed.fetch("result") == "continue-skipped-completed"
  raise "continuous completed turn registered another cycle" unless File.readlines(cron_log, chomp: true).length == cron_before_completed

  continuous_failed = JSON.parse(run!(continuous_cycle_environment.merge(
    "CODEX_TEST_LATEST_TURN_ID" => "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff",
    "CODEX_TEST_LATEST_TURN_STATUS" => "failed"
  ), *continuous_options))
  raise "continuous failed turn was not queued and re-armed" unless continuous_failed.fetch("result") == "continue-queued-and-rearmed"
  raise "continuous failed turn did not send exactly once" unless File.readlines(command_log, chomp: true).length == continuous_command_count + 1

  continuous_interrupted_options = interrupted_guard_options[0...-1] + ["--until-complete", "--json"]
  false_completed_cycle = JSON.parse(run!(continuous_cycle_environment.merge(
    "CODEX_TEST_LATEST_TURN_STATUS" => "completed"
  ), *continuous_interrupted_options))
  unless false_completed_cycle.fetch("result") == "continue-queued-and-rearmed"
    raise "continuous mode stopped on a technical completion of the same interrupted turn"
  end
  false_completed_cron = JSON.parse(File.readlines(cron_log, chomp: true).last)
  false_completed_argv = JSON.parse(false_completed_cron.fetch(false_completed_cron.index("--command-argv") + 1))
  unless false_completed_argv.each_cons(2).any? { |left, right| left == "--guard-status" && right == "interrupted" }
    raise "continuous mode forgot the original incomplete guard after technical completion"
  end

  continuous_resumed = JSON.parse(run!(continuous_cycle_environment.merge(
    "CODEX_TEST_LATEST_TURN_ID" => "cccccccc-dddd-4eee-8fff-aaaaaaaaaaaa",
    "CODEX_TEST_LATEST_TURN_STATUS" => "interrupted",
    "CODEX_TEST_QUEUE_FAIL" => "1"
  ), *continuous_options))
  raise "continuous exec fallback did not re-arm" unless continuous_resumed.fetch("result") == "continue-resumed-and-rearmed"

  turn_state_file = continuous_cycle_environment.fetch("CODEX_TEST_TURN_STATE_FILE")
  FileUtils.rm_f(turn_state_file)
  cron_before_resume_completion = File.readlines(cron_log, chomp: true).length
  completed_after_resume = JSON.parse(run!(continuous_cycle_environment.merge(
    "CODEX_TEST_LATEST_TURN_ID" => "dddddddd-eeee-4fff-8aaa-bbbbbbbbbbbb",
    "CODEX_TEST_LATEST_TURN_STATUS" => "failed",
    "CODEX_TEST_QUEUE_FAIL" => "1",
    "CODEX_TEST_AFTER_EXEC_TURN_ID" => "eeeeeeee-ffff-4111-8bbb-cccccccccccc",
    "CODEX_TEST_AFTER_EXEC_TURN_STATUS" => "completed"
  ), *continuous_options))
  raise "continuous exec completion did not stop" unless completed_after_resume.fetch("result") == "continue-resumed-completed"
  raise "continuous exec completion registered another cycle" unless File.readlines(cron_log, chomp: true).length == cron_before_resume_completion
  FileUtils.rm_f(turn_state_file)

  fail_run!(continuous_cycle_environment.merge(
    "CODEX_TEST_PRIMARY_RESET" => "0",
    "CODEX_TEST_SECONDARY_RESET" => "0"
  ), *continuous_options)
  fail_run!(continuous_cycle_environment, *run_options[0...-1], "--until-complete", "--json")
  fail_run!(environment, "continue-run", "--alias", "sleeper", "--thread", "not-a-uuid", "--cwd", temporary, "--message", "继续", "--codex-bin", fake_codex)
end

puts "agent-identity tests ok"
