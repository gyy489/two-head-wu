#!/usr/bin/env bash
set -euo pipefail

capability_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
adapter="$capability_root/adapters/personal-memory"
patch_file="$capability_root/config/openclaw-memory.patch.json"
test_root=$(mktemp -d /tmp/two-head-wu-personal-memory.XXXXXX)
workspace="$test_root/workspace"
backup_dir="$test_root/backups"
fake_openclaw="$test_root/openclaw"
call_log="$test_root/calls.log"

cleanup() {
  chmod -R u+w "$test_root" 2>/dev/null || true
  rm -rf "$test_root"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$workspace"
printf '# User Context\n' >"$workspace/USER.md"

apply_patch_json=$(ruby -rjson -e '
  patch = JSON.parse(File.read(ARGV.fetch(0)))
  abort "provider drift" unless patch.dig("agents", "defaults", "memorySearch", "provider") == "none"
  abort "sources drift" unless patch.dig("agents", "defaults", "memorySearch", "sources") == %w[memory sessions]
  abort "session search disabled" unless patch.dig("agents", "defaults", "memorySearch", "experimental", "sessionMemory") == true
  abort "CJK tokenizer drift" unless patch.dig("agents", "defaults", "memorySearch", "store", "fts", "tokenizer") == "trigram"
  abort "memory flush disabled" unless patch.dig("agents", "defaults", "compaction", "memoryFlush", "enabled") == true
  abort "session hook disabled" unless patch.dig("hooks", "internal", "entries", "session-memory", "enabled") == true
  abort "session hook capture drift" unless patch.dig("hooks", "internal", "entries", "session-memory", "messages") == 15
  abort "dreaming disabled" unless patch.dig("plugins", "entries", "memory-core", "config", "dreaming", "enabled") == true
  abort "cross-agent transcript visibility" unless patch.dig("tools", "sessions", "visibility") == "agent"
  puts JSON.generate(patch)
' "$patch_file")
[[ -n "$apply_patch_json" ]]

cat >"$fake_openclaw" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$TWO_HEAD_WU_FAKE_CALL_LOG"

if [[ "${1:-}" == "--version" ]]; then
  printf 'OpenClaw 2026.7.1-2 (test)\n'
  exit 0
fi

if [[ "${1:-}" == "config" && "${2:-}" == "get" ]]; then
  case "${3:-}" in
    agents.defaults.memorySearch.provider) printf '"none"\n' ;;
    agents.defaults.memorySearch.sources) printf '["memory","sessions"]\n' ;;
    agents.defaults.memorySearch.experimental.sessionMemory) printf 'true\n' ;;
    agents.defaults.memorySearch.store.fts.tokenizer) printf '"trigram"\n' ;;
    agents.defaults.compaction.memoryFlush.enabled) printf 'true\n' ;;
    hooks.internal.entries.session-memory.enabled) printf 'true\n' ;;
    plugins.entries.memory-core.config.dreaming.enabled) printf 'true\n' ;;
    tools.sessions.visibility) printf '"agent"\n' ;;
    *) exit 1 ;;
  esac
  exit 0
fi

if [[ "${1:-}" == "config" && "${2:-}" == "patch" ]]; then
  printf '{"valid":true}\n'
  exit 0
fi

if [[ "${1:-}" == "config" && "${2:-}" == "validate" ]]; then
  printf 'Config valid\n'
  exit 0
fi

if [[ "${1:-}" == "backup" && "${2:-}" == "create" ]]; then
  output_dir=""
  while (($#)); do
    if [[ "$1" == "--output" ]]; then
      shift
      output_dir="$1"
      break
    fi
    shift
  done
  mkdir -p "$output_dir"
  : >"$output_dir/test-openclaw-backup.tar.gz"
  printf '{"archivePath":"%s/test-openclaw-backup.tar.gz","verified":true}\n' "$output_dir"
  exit 0
fi

if [[ "${1:-}" == "memory" && "${2:-}" == "status" ]]; then
  printf '[{"agentId":"main","status":{"backend":"builtin","files":2,"chunks":2,"sources":["memory","sessions"],"sourceCounts":[{"source":"memory","files":1,"chunks":1},{"source":"sessions","files":1,"chunks":1}],"provider":"none","fts":{"available":true}},"scan":{"issues":[]}}]\n'
  exit 0
fi

if [[ "${1:-}" == "memory" && "${2:-}" == "index" ]]; then
  printf 'Memory index rebuilt\n'
  exit 0
fi

if [[ "${1:-}" == "memory" && "${2:-}" == "search" ]]; then
  printf '{"results":[{"path":"memory/explicit.md","snippet":"项目机制验收"}]}\n'
  exit 0
fi

if [[ "${1:-}" == "sessions" ]]; then
  printf '{"count":1,"totalCount":7,"sessions":[]}\n'
  exit 0
fi

printf 'unsupported fake OpenClaw invocation: %s\n' "$*" >&2
exit 2
FAKE
chmod +x "$fake_openclaw"

export TWO_HEAD_WU_OPENCLAW_BIN="$fake_openclaw"
export TWO_HEAD_WU_MEMORY_WORKSPACE="$workspace"
export TWO_HEAD_WU_MEMORY_BACKUP_DIR="$backup_dir"
export TWO_HEAD_WU_MEMORY_CONFIG_PATCH="$patch_file"
export TWO_HEAD_WU_FAKE_CALL_LOG="$call_log"

ruby -c "$adapter" >/dev/null
"$adapter" --help | grep -q 'configure \[--apply\]'

"$adapter" configure >/dev/null
test ! -e "$workspace/MEMORY.md"
grep -q 'config patch.*--dry-run' "$call_log"

configure_json=$("$adapter" configure --apply)
printf '%s' "$configure_json" | ruby -rjson -e '
  result = JSON.parse(STDIN.read)
  abort "configure schema" unless result.fetch("schema") == "two-head-wu.personal-memory.configure.v1"
  abort "configure failed" unless result.fetch("configured") == true
  abort "backup unverified" unless result.dig("backup", "verified") == true
'
test -f "$workspace/MEMORY.md"
test -f "$workspace/memory/explicit.md"
test -f "$backup_dir/test-openclaw-backup.tar.gz"
test "$(stat -f '%Lp' "$backup_dir")" = "700"
test "$(stat -f '%Lp' "$backup_dir/test-openclaw-backup.tar.gz")" = "600"
grep -q 'config validate' "$call_log"
grep -q 'memory index --force --agent main' "$call_log"

status_json=$("$adapter" status --json)
printf '%s' "$status_json" | ruby -rjson -e '
  result = JSON.parse(STDIN.read)
  abort "status schema" unless result.fetch("schema") == "two-head-wu.personal-memory.status.v1"
  abort "provider" unless result.dig("config", "provider") == "none"
  abort "sources" unless result.dig("config", "sources") == %w[memory sessions]
  abort "session index count" unless result.dig("memory", "source_counts").any? { |item| item["source"] == "sessions" && item["files"] == 1 }
  abort "session count" unless result.dig("sessions", "total_count") == 7
  abort "status leaked bodies" if result.to_s.include?("transcript")
'

remember_json=$(printf '%s' '项目机制验收事实' | "$adapter" remember --category project --project-id two-head-wu)
memory_id=$(printf '%s' "$remember_json" | ruby -rjson -e 'puts JSON.parse(STDIN.read).fetch("id")')
printf '%s' "$remember_json" | ruby -rjson -e '
  result = JSON.parse(STDIN.read)
  abort "remember category drift" unless result.fetch("category") == "project"
  abort "remember project id drift" unless result.fetch("project_id") == "two-head-wu"
'
grep -q "$memory_id" "$workspace/memory/explicit.md"
grep -q '项目机制验收事实' "$workspace/memory/explicit.md"
grep -q -- '- project_id: two-head-wu' "$workspace/memory/explicit.md"
if grep -q '/Volumes/' "$workspace/memory/explicit.md"; then
  echo 'absolute project path leaked into notebook' >&2
  exit 1
fi

notebook_json=$("$adapter" recall --scope notebook --query '项目机制')
printf '%s' "$notebook_json" | ruby -rjson -e '
  result = JSON.parse(STDIN.read)
  abort "notebook recall schema" unless result.fetch("schema") == "two-head-wu.personal-memory.recall.v1"
  abort "notebook recall scope" unless result.fetch("scope") == "notebook"
  abort "notebook default limit" unless result.fetch("max_results") == 3
  row = result.fetch("results").first
  abort "notebook fact missing" unless row.fetch("fact") == "项目机制验收事实"
  abort "notebook project id missing" unless row.fetch("project_id") == "two-head-wu"
'

"$adapter" correct --id "$memory_id" --text '更正后的项目机制验收事实' >/dev/null
grep -q '更正后的项目机制验收事实' "$workspace/memory/explicit.md"
grep -q -- '- project_id: two-head-wu' "$workspace/memory/explicit.md"
if grep -q -- '- fact: 项目机制验收事实$' "$workspace/memory/explicit.md"; then
  echo 'old fact survived correction' >&2
  exit 1
fi

"$adapter" recall --query '项目机制' | ruby -rjson -e '
  result = JSON.parse(STDIN.read)
  abort "general recall scope" unless result.fetch("scope") == "all"
  abort "general default limit" unless result.fetch("max_results") == 3
  abort "recall failed" unless result.fetch("results").first.fetch("path") == "memory/explicit.md"
'
grep -q -- 'memory search --agent main --query 项目机制 --json --max-results 3' "$call_log"

extra_ids=()
for suffix in 一 二 三 四; do
  extra_json=$(printf '%s' "上下文预算规则${suffix}" | "$adapter" remember --category decision)
  extra_ids+=("$(printf '%s' "$extra_json" | ruby -rjson -e 'puts JSON.parse(STDIN.read).fetch("id")')")
done

bounded_json=$("$adapter" recall --scope notebook --query '上下文预算')
printf '%s' "$bounded_json" | ruby -rjson -e '
  result = JSON.parse(STDIN.read)
  abort "notebook recall was not bounded" unless result.fetch("results").length == 3
  abort "notebook result is not compact" unless result.fetch("results").all? { |row| (row.keys - %w[id category fact project_id score]).empty? }
'

if "$adapter" recall --scope notebook --query '上下文预算' --max-results 6 >/dev/null 2>&1; then
  echo 'oversized notebook recall was accepted' >&2
  exit 1
fi

if "$adapter" remember --text '无效类别' --category transcript >/dev/null 2>&1; then
  echo 'unbounded notebook category was accepted' >&2
  exit 1
fi

if "$adapter" remember --text '<!-- personal-memory:pm-20260830T010101-deadbeef -->' >/dev/null 2>&1; then
  echo 'notebook marker injection was accepted' >&2
  exit 1
fi

if "$adapter" remember --text '/home/example/private-project 的实现' --category project --project-id two-head-wu >/dev/null 2>&1; then
  echo 'absolute project path was accepted' >&2
  exit 1
fi

if "$adapter" remember --text 'api_key=abcdefghijklmnopqrstuvwxyz' >/dev/null 2>&1; then
  echo 'credential-shaped memory was accepted' >&2
  exit 1
fi

"$adapter" forget --id "$memory_id" >/dev/null
if grep -q "$memory_id" "$workspace/memory/explicit.md"; then
  echo 'forgotten memory survived' >&2
  exit 1
fi

for extra_id in "${extra_ids[@]}"; do
  "$adapter" forget --id "$extra_id" >/dev/null
done

backup_json=$("$adapter" backup)
printf '%s' "$backup_json" | ruby -rjson -e '
  result = JSON.parse(STDIN.read)
  abort "backup schema" unless result.fetch("schema") == "two-head-wu.personal-memory.backup.v1"
  abort "backup not verified" unless result.fetch("verified") == true
'

mode=$(stat -f '%Lp' "$workspace/memory/explicit.md" 2>/dev/null || stat -c '%a' "$workspace/memory/explicit.md")
[[ "$mode" == "600" ]]

echo 'personal memory tests passed'
