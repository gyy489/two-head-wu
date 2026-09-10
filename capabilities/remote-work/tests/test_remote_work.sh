#!/bin/zsh
set -eu
setopt pipefail

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
client="$project_root/capabilities/remote-work/adapters/remote-work"
admin="$project_root/capabilities/remote-work/adapters/remote-work-admin"
deploy="$project_root/capabilities/remote-work/adapters/remote-work-deploy"
worker="$project_root/capabilities/remote-work/worker/ltw-worker"
server="$project_root/capabilities/remote-work/server/control_plane.py"
test_root=$(mktemp -d /tmp/two-head-wu-remote-integration.XXXXXX)
server_pid=""

cleanup() {
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" >/dev/null 2>&1 || true
    wait "$server_pid" >/dev/null 2>&1 || true
  fi
  chmod -R u+w "$test_root" 2>/dev/null || true
  rm -rf "$test_root"
}
trap cleanup EXIT HUP INT TERM

cd "$project_root"
test_signing_key="$test_root/release-signing.pem"
test_public_key="$test_root/release-signing-public.pem"
ruby -ropenssl -e 'key=OpenSSL::PKey::RSA.new(2048); File.binwrite(ARGV[0],key.to_pem); File.binwrite(ARGV[1],key.public_key.to_pem)' "$test_signing_key" "$test_public_key"
chmod 600 "$test_signing_key"
export WU_REMOTE_RELEASE_SIGNING_KEY_FILE="$test_signing_key"
export WU_REMOTE_RELEASE_PUBLIC_KEY_FILE="$test_public_key"
export WU_REMOTE_TEST_BUILD_ROOT="$test_root/build"
export WU_CAPABILITY_RELEASE_HOME="$test_root/capability-releases"
core/bin/wu packages update --project two-head-wu --apply --json >/dev/null
ruby capabilities/remote-work/tests/test_remote_work.rb
scripts/capabilities-manager sync-skills --apply --isolated | rg -q "external runtime surfaces unchanged"
"$deploy" help | rg -q "production-air-sync-smoke"
ruby -c capabilities/remote-work/lib/remote_work.rb >/dev/null
ruby -c "$client" >/dev/null
ruby -c "$admin" >/dev/null
ruby -c "$deploy" >/dev/null
ruby -c "$worker" >/dev/null
python3 -m py_compile "$server"
python3 capabilities/remote-work/tests/test_control_plane.py >/dev/null
python3 capabilities/remote-work/tests/test_multi_user_contracts.py >/dev/null
python3 capabilities/remote-work/tests/test_member_control_plane.py >/dev/null
python3 capabilities/remote-work/tests/test_member_auth.py >/dev/null
capabilities/remote-work/tests/test_native_member_keys.sh >/dev/null
(cd capabilities/remote-work/native/member-air && go test ./... && go vet ./...)
(cd capabilities/remote-work/native/member-air && GOOS=windows GOARCH=amd64 go build -o "$test_root/member-air-windows.exe" .)
skill_validator="skills/.active/skill-creator/scripts/quick_validate.py"
if [[ ! -f "$skill_validator" ]]; then
  skill_validator="skills/.active/.system/skill-creator/scripts/quick_validate.py"
fi
python3 "$skill_validator" capabilities/remote-work/skills/remote-work >/dev/null
"$admin" build >/dev/null
WU_REMOTE_TEST_BUILD_VARIANT=integration-dev "$admin" build --channel dev >/dev/null
ruby -rjson -r "$project_root/capabilities/remote-work/lib/remote_work.rb" -e '
  manifest=JSON.parse(File.read(ARGV.fetch(0)))
  public_key=File.read(ARGV.fetch(1))
  RemoteWork::CapabilityCatalogSignature.verify!(manifest, public_key)
  ids=manifest.fetch("capabilities").map { |item| item.fetch("id") }
  forbidden=%w[memory:personal mcp:private-memory tool:identity-catalog tool:resource-catalog research-library:export workflow:sync-air]
  abort "member catalog leaked an owner-only capability" unless (ids & forbidden).empty?
  abort "member catalog lost the member project capability" unless ids.include?("codex:project-task")
  abort "member catalog lost the self-only Codex status capability" unless ids.include?("tool:codex-status")
' "$WU_REMOTE_TEST_BUILD_ROOT/capabilities/air-manifest.json" "$test_public_key"
ruby -rjson -rdigest -r "$project_root/capabilities/remote-work/lib/remote_work.rb" -e '
  manifest=JSON.parse(File.read(ARGV.fetch(0)))
  public_key=File.read(ARGV.fetch(1))
  components=File.dirname(ARGV.fetch(0))
  RemoteWork::ModuleSignature.verify!(manifest, public_key)
  ids=manifest.fetch("modules").map { |item| item.fetch("id") }
  expected=%w[skill:remote-work skill:paper-writing skill:paper-navigator]
  abort "member portable module allowlist drift" unless ids.sort==expected.sort
  forbidden=%w[skill:agent-identity skill:two-head-wu skill:server-operations memory:personal mcp:private-memory]
  abort "member module catalog leaked a protected module" unless (ids & forbidden).empty?
  manifest.fetch("modules").each do |item|
    abort "member module is not active and portable" unless item["status"]=="active" && item["classification"]=="portable"
    archive=File.join(components,item.fetch("archive"))
    abort "member module archive is unavailable" unless File.file?(archive)
    abort "member module archive hash drift" unless Digest::SHA256.file(archive).hexdigest==item.fetch("sha256")
  end
' "$WU_REMOTE_TEST_BUILD_ROOT/components/air-manifest.json" "$test_public_key"
"$deploy" health >/dev/null
if env TWO_HEAD_WU_ALIYUN_SSH_TARGET='' "$deploy" inspect --project two-head-wu >"$test_root/deploy-no-target.out" 2>"$test_root/deploy-no-target.err"; then
  print -u2 -- "deploy adapter accepted a missing protected target"
  exit 1
fi
rg -q "protected SSH target is not installed" "$test_root/deploy-no-target.err"

python3 "$server" --root "$test_root/server" init >/dev/null
cp -R "$WU_REMOTE_TEST_BUILD_ROOT/components/." "$test_root/server/components/published/"
cp -R "$WU_REMOTE_TEST_BUILD_ROOT/capabilities/." "$test_root/server/capabilities/published/"
cp -R "$WU_REMOTE_TEST_BUILD_ROOT/releases/." "$test_root/server/releases/"
port=$(ruby -rsocket -e 'socket=TCPServer.new("127.0.0.1", 0); print socket.addr[1]; socket.close')
python3 "$server" --root "$test_root/server" serve --bind 127.0.0.1 --port "$port" >"$test_root/server.log" 2>&1 &
server_pid=$!
endpoint="http://127.0.0.1:$port/two-head-wu/v1"
for _attempt in {1..40}; do
  curl --fail --silent "$endpoint/health" >/dev/null 2>&1 && break
  sleep 0.1
done
curl --fail --silent "$endpoint/health" >/dev/null

air_token=$(python3 "$server" --root "$test_root/server" issue-enrollment --device owner-air --role owner-air --ttl 3600)
worker_token=$(python3 "$server" --root "$test_root/server" issue-enrollment --device mac-mini-worker --role mac-mini-worker --ttl 3600)
export WU_REMOTE_ALLOW_HTTP=1
export WU_REMOTE_SECRET_STORE=file
export WU_TEST_ENROLLMENT="$air_token"
WU_REMOTE_HOME="$test_root/air-home" "$client" enroll --endpoint "$endpoint" --device owner-air --token-env WU_TEST_ENROLLMENT --secret-store file >/dev/null
if WU_REMOTE_HOME="$test_root/replay-home" "$client" enroll --endpoint "$endpoint" --device owner-air --token-env WU_TEST_ENROLLMENT --secret-store file >"$test_root/replay.out" 2>"$test_root/replay.err"; then
  print -u2 -- "single-use enrollment token was accepted twice"
  exit 1
fi
rg -q "invalid or expired" "$test_root/replay.err"

export WU_TEST_ENROLLMENT="$worker_token"
WU_REMOTE_HOME="$test_root/worker-home" "$client" enroll --endpoint "$endpoint" --device mac-mini-worker --token-env WU_TEST_ENROLLMENT --secret-store file >/dev/null
unset WU_TEST_ENROLLMENT

WU_REMOTE_HOME="$test_root/air-home" "$client" diagnose >/dev/null
WU_REMOTE_WORKER_HOME="$test_root/worker-home" "$worker" health >/dev/null

export WU_REMOTE_HOME="$test_root/air-home"
export WU_REMOTE_SKILLS_HOME="$test_root/air-skills"
"$client" modules list | rg -q '^skill:remote-work'
"$client" modules pull skill:remote-work >/dev/null
"$client" policy set skill:remote-work auto-update >/dev/null
"$client" modules status | rg -q $'^skill:remote-work\tauto-update\t[^\t]+\t[^\t]+\tcurrent$'
module_version=$("$client" modules versions skill:remote-work | sed -n '1s/\t.*//p')
print -r -- "$module_version" | rg -q '^[a-f0-9]{16}$'
"$client" modules rollback skill:remote-work "$module_version" >/dev/null
"$client" modules status | rg -q $'^skill:remote-work\tpinned\t[^\t]+\t[^\t]+\tcurrent$'
"$client" policy set skill:remote-work auto-update >/dev/null
if "$client" modules pull mcp:private-memory >"$test_root/remote-only.out" 2>"$test_root/remote-only.err"; then
  print -u2 -- "remote-only module was downloaded"
  exit 1
fi
rg -q "只能在 Mac mini 远程使用" "$test_root/remote-only.err"
test -f "$test_root/air-skills/remote-work/SKILL.md"

project="$test_root/sample-project"
mkdir -p "$project/.git" "$project/node_modules/pkg" "$project/src"
print 'hello' >"$project/src/input.txt"
print 'SECRET=must-not-transfer' >"$project/.env"
print 'private' >"$project/device.key"
print 'ignored' >"$project/node_modules/pkg/cache.txt"

# File artifacts are independently hashed, idempotent, scoped to the owner device, and materialized only
# inside the leased job workspace.
print '# Air 附件\n' >"$test_root/attachment.md"
artifact_request=call-abcdef0123456789abcdef01
"$client" artifacts upload "$test_root/attachment.md" --media-type text/markdown --request-id "$artifact_request" >"$test_root/artifact-first.json"
"$client" artifacts upload "$test_root/attachment.md" --media-type text/markdown --request-id "$artifact_request" >"$test_root/artifact-second.json"
artifact_id=$(ruby -rjson -e 'print JSON.parse(File.read(ARGV[0])).dig("artifact","id")' "$test_root/artifact-first.json")
artifact_second=$(ruby -rjson -e 'print JSON.parse(File.read(ARGV[0])).dig("artifact","id")' "$test_root/artifact-second.json")
[[ "$artifact_id" == "$artifact_second" ]]
"$client" artifacts recover "$artifact_request" | rg -q "\"$artifact_id\""
"$client" artifacts list | rg -q "^$artifact_id"
downloaded_artifact=$("$client" artifacts fetch "$artifact_id")
cmp "$test_root/attachment.md" "$downloaded_artifact"
if "$client" artifacts upload "$project/device.key" >"$test_root/bad-artifact.out" 2>"$test_root/bad-artifact.err"; then
  print -u2 -- "credential-shaped artifact was accepted"
  exit 1
fi
rg -q "credential-shaped" "$test_root/bad-artifact.err"

# Model discovery is published by the worker without exposing Codex account data.
WU_REMOTE_HOME="$test_root/worker-home" ruby -r "$project_root/capabilities/remote-work/lib/remote_work.rb" -e 'config=RemoteWork::Config.new; RemoteWork::HTTPClient.new(config).post("worker/models", {"models"=>[{"id"=>"fake-model","display_name"=>"Fake Model","default_effort"=>"medium","efforts"=>["low","medium","high"],"is_default"=>true}]})' >/dev/null
WU_REMOTE_HOME="$test_root/worker-home" ruby -r "$project_root/capabilities/remote-work/lib/remote_work.rb" -e 'config=RemoteWork::Config.new; runtime={"schema_version"=>1,"protocol_min"=>RemoteWork::PROTOCOL_VERSION,"protocol_max"=>RemoteWork::PROTOCOL_VERSION,"runtimes"=>[{"runtime_kind"=>"two-head-wu-worker","runtime_version"=>RemoteWork::VERSION,"native_schema_hash"=>"a"*64,"adapter_version"=>RemoteWork::VERSION,"health"=>"compatible","supported_features"=>%w[capability-call project-delta]},{"runtime_kind"=>"codex-app-server","runtime_version"=>"test","native_schema_hash"=>"b"*64,"adapter_version"=>RemoteWork::VERSION,"health"=>"compatible","supported_features"=>%w[project-task]}]}; RemoteWork::HTTPClient.new(config).post("worker/presence", {"runtime_version"=>RemoteWork::VERSION,"capabilities"=>%w[air-sync-pipeline artifact-relay capability-adapters codex-job codex-status identity-catalog interaction-relay model-catalog openai-docs-mcp project-delta project-workflows research-library-provider resource-catalog result-package runtime-catalog],"runtime_catalog"=>runtime})' >/dev/null
expected_inventory_count=$(ruby -rjson -e 'print JSON.parse(File.read(ARGV.fetch(0))).fetch("entries").length' "$WU_REMOTE_TEST_BUILD_ROOT/capabilities/inventory.json")
expected_capability_count=$(ruby -rjson -e 'print JSON.parse(File.read(ARGV.fetch(0))).fetch("capabilities").length' "$WU_REMOTE_TEST_BUILD_ROOT/capabilities/manifest.json")
python3 "$server" --root "$test_root/server" doctor | ruby -rjson -e 'value=JSON.parse(STDIN.read); abort "doctor lost model count" unless value.fetch("models")==1; abort "doctor lost capability count" unless value.fetch("capabilities")==Integer(ARGV.fetch(1)); abort "doctor lost inventory count" unless value.fetch("inventory_entries")==Integer(ARGV.fetch(0))' "$expected_inventory_count" "$expected_capability_count"
"$client" models list | rg -q $'^fake-model\t默认\tmedium\tlow,medium,high'
"$client" tools list | rg -q $'^codex-status\tCodex 额度状态\tread-only\tmac-mini'
"$client" abilities list --json >"$test_root/abilities.json"
ruby -rjson -e '
  value=JSON.parse(File.read(ARGV[0]));
  abort "catalog signature was not verified" unless value["catalog_signature"]=="verified";
  abort "directory was not live" unless value["directory_source"]=="live";
  abort "Mini was not discovered online" unless value.dig("mini","online")==true;
  local=value.fetch("local_capabilities"); remote=value.fetch("remote_capabilities");
  abort "Air local capability lost name/function" if local.any?{|item|item["name"].to_s.empty? || item["summary"].to_s.empty?};
  abort "installed portable skill was not discovered" unless local.any?{|item|item["id"]=="skill:remote-work" && item["availability"]=="ready"};
  abort "read-only tool is not named and auto-callable" unless remote.any?{|item|item["id"]=="tool:codex-status" && item["name"]=="Codex 额度状态" && item["availability"]=="ready" && item["invocation_policy"]=="auto"};
  abort "private memory was falsely callable" unless remote.any?{|item|item["id"]=="mcp:private-memory" && item["availability"]=="metadata-only" && item["invocation_policy"]=="unavailable"};
  inventory=value.fetch("mini_inventory"); abort "Mini inventory signature was not verified" unless inventory["signature"]=="verified";
  expected=JSON.parse(File.read(ARGV.fetch(1))).fetch("entries");
  expected_counts=expected.group_by{|item|item.fetch("kind")}.transform_values(&:length);
  abort "Mini inventory count drift" unless inventory["total"]==expected.length && expected_counts.all?{|kind,count|inventory.dig("counts_by_kind",kind)==count};
  entries=inventory.fetch("entries");
  abort "Mini inventory lost name/function" if entries.any?{|item|item["name"].to_s.empty? || item["summary"].to_s.empty?};
  abort "portable Skill classification drift" unless entries.any?{|item|item["id"]=="skill:paper-writing" && item["air_mode"]=="portable"};
  abort "ordinary remote Skill classification drift" unless entries.any?{|item|item["id"]=="skill:research-survey" && item["air_mode"]=="remote-queue" && item["callable_via"]=="codex:project-task"};
  abort "owner step-up Skill classification drift" unless entries.any?{|item|item["id"]=="skill:server-operations" && item["air_mode"]=="portable" && !item.key?("callable_via")};
  abort "OpenAI Docs MCP was not routed to its exact adapter" unless entries.any?{|item|item["id"]=="mcp:openai-developer-docs" && item["air_mode"]=="remote-auto" && item["callable_via"]=="mcp-tool:openai-docs"};
  abort "resource catalog was not remotely queryable" unless entries.any?{|item|item["id"]=="resource:edge-server" && item["air_mode"]=="remote-auto" && item["callable_via"]=="tool:resource-catalog"};
  abort "research library was not routed through its provider" unless entries.any?{|item|item["id"]=="resource:private-data-service" && item["air_mode"]=="remote-auto" && item["callable_via"]=="research-library:search"};
  abort "write workflow lost confirmation policy" unless entries.any?{|item|item["id"]=="workflow:refresh-documentation" && item["air_mode"]=="confirm" && item["callable_via"]=="workflow:refresh-documentation"};
  abort "Air sync pipeline was not published with confirmation" unless entries.any?{|item|item["id"]=="workflow:sync-air" && item["air_mode"]=="confirm" && item["callable_via"]=="workflow:sync-air"};
  abort "unconfigured agent was falsely callable" unless entries.any?{|item|item["id"]=="agent:evoscientist" && item["air_mode"]=="unavailable"};
  forbidden=%w[path command endpoint private_ref secret_ref executable workspace device_secret access_token];
  abort "Mini inventory leaked protected fields" if entries.any?{|item| !(item.keys & forbidden).empty?};
' "$test_root/abilities.json" "$WU_REMOTE_TEST_BUILD_ROOT/capabilities/inventory.json"
"$client" abilities local >"$test_root/abilities-local.txt"
"$client" abilities remote >"$test_root/abilities-remote.txt"
rg -q '^Air 本地能力$' "$test_root/abilities-local.txt"
rg -q '^Mini 可执行入口$' "$test_root/abilities-remote.txt"
rg -q "^Mini 完整功能表（${expected_inventory_count} 项）$" "$test_root/abilities-remote.txt"
WU_REMOTE_HOME="$test_root/air-home" WU_REMOTE_SECRET_STORE=file "$project_root/core/bin/wu" 能做什么 --json | ruby -rjson -e 'value=JSON.parse(STDIN.read); abort "core shortcut lost dynamic catalog" unless value["catalog_signature"]=="verified"'
if "$client" jobs submit --project "$project" --model fake-model --effort ultra -- "不支持的推理强度" >"$test_root/bad-model.out" 2>"$test_root/bad-model.err"; then
  print -u2 -- "unsupported model effort was accepted"
  exit 1
fi
rg -q "not supported" "$test_root/bad-model.err"

# Repeating the same explicit request ID resolves to one job instead of duplicating work.
dedupe_request=call-0123456789abcdef01234567
"$client" jobs submit --project "$project" --request-id "$dedupe_request" -- "幂等提交" >"$test_root/dedupe-first.json"
"$client" jobs submit --project "$project" --request-id "$dedupe_request" -- "幂等提交" >"$test_root/dedupe-second.json"
dedupe_first=$(ruby -rjson -e 'print JSON.parse(File.read(ARGV[0])).dig("job","id")' "$test_root/dedupe-first.json")
dedupe_second=$(ruby -rjson -e 'print JSON.parse(File.read(ARGV[0])).dig("job","id")' "$test_root/dedupe-second.json")
[[ "$dedupe_first" == "$dedupe_second" ]]
"$client" jobs recover "$dedupe_request" | rg -q "\"$dedupe_first\""
"$client" jobs cancel "$dedupe_first" >/dev/null

# Exercise the Air <-> relay <-> worker approval mailbox and Chinese reply command.
"$client" jobs submit --project "$project" --model fake-model --effort high -- "等待 Air 审批" >"$test_root/interaction-job.json"
interaction_values=$(WU_REMOTE_HOME="$test_root/worker-home" ruby -r "$project_root/capabilities/remote-work/lib/remote_work.rb" -e 'config=RemoteWork::Config.new; http=RemoteWork::HTTPClient.new(config); lease=http.get("worker/jobs/lease"); job=lease.fetch("job"); id=job.fetch("id"); token=job.fetch("lease_id"); http.post("worker/jobs/#{id}/state", {"lease_id"=>token,"state"=>"running","message"=>"running"}); ask=http.post("worker/jobs/#{id}/interactions", {"lease_id"=>token,"kind"=>"command-approval","prompt"=>{"title"=>"测试审批","command"=>"printf ok"}}).fetch("interaction"); print [id,ask.fetch("id"),token].join(" ")')
interaction_job=${interaction_values%% *}
interaction_rest=${interaction_values#* }
interaction_id=${interaction_rest%% *}
interaction_lease=${interaction_values##* }
"$client" jobs interactions "$interaction_job" | rg -q '"status": "pending"'
WU_REMOTE_COMPANION_NO_UI=1 "$client" companion once | rg -q "$interaction_id"
WU_REMOTE_HOME="$test_root/air-home" WU_REMOTE_SECRET_STORE=file "$project_root/core/bin/wu" 回复任务 "$interaction_job" "$interaction_id" 接受 >/dev/null
WU_REMOTE_HOME="$test_root/worker-home" ruby -r "$project_root/capabilities/remote-work/lib/remote_work.rb" -e 'config=RemoteWork::Config.new; http=RemoteWork::HTTPClient.new(config); value=http.get("worker/jobs/#{ARGV[0]}/interactions/#{ARGV[1]}/reply?lease_id=#{ARGV[2]}"); abort "reply missing" unless value.dig("reply","decision")=="accept"; abort "job did not resume" unless value["job_state"]=="running"; heartbeat=http.post("worker/jobs/#{ARGV[0]}/heartbeat",{"lease_id"=>ARGV[2]}); abort "heartbeat state drift" unless heartbeat.dig("job","state")=="running"' "$interaction_job" "$interaction_id" "$interaction_lease"
"$client" jobs cancel "$interaction_job" >/dev/null

# A referenced artifact reaches only this isolated job and is visible in the worker's test inventory.
"$client" jobs submit --project "$project" --artifact "$artifact_id" -- "读取附件" >"$test_root/artifact-job.json"
artifact_job=$(ruby -rjson -e 'print JSON.parse(File.read(ARGV[0])).dig("job","id")' "$test_root/artifact-job.json")
WU_REMOTE_WORKER_HOME="$test_root/worker-home" "$worker" once --queue legacy-owner --executor test >/dev/null
artifact_result=$("$client" jobs fetch "$artifact_job")
ruby -rjson -e 'value=JSON.parse(File.read(ARGV[0])); id=ARGV[1]; files=value.fetch("workspace_files"); abort "artifact missing from isolated workspace" unless files.include?(".two-head-wu-inputs/#{id}/attachment.md"); abort "artifact manifest missing" unless files.include?(".two-head-wu-inputs/manifest.json")' "$artifact_result/tests.json" "$artifact_id"
"$client" artifacts remove "$artifact_id" | rg -q '"state": "removed"'
if "$client" artifacts fetch "$artifact_id" >"$test_root/removed-artifact.out" 2>"$test_root/removed-artifact.err"; then
  print -u2 -- "removed artifact remained downloadable"
  exit 1
fi
rg -q "不可下载" "$test_root/removed-artifact.err"

# A read-only tool uses the same offline queue but returns a versioned, redacted JSON result.
( sleep 0.5; WU_REMOTE_WORKER_HOME="$test_root/worker-home" "$worker" once --queue legacy-owner --executor test >"$test_root/tool-worker.log" ) &
tool_worker_pid=$!
"$client" tools invoke codex-status --json --timeout 20 >"$test_root/codex-status.json"
wait "$tool_worker_pid"
ruby -rjson -e 'value=JSON.parse(File.read(ARGV[0])); abort "tool schema drift" unless value["schema"]=="two-head-wu.codex-status.v1"; abort "tool source drift" unless value["source_device"]=="mac-mini-worker"; abort "tool leaked local paths" if File.read(ARGV[0]).include?("codex_home") || File.read(ARGV[0]).include?("CODEX_HOME")' "$test_root/codex-status.json"
( sleep 0.5; WU_REMOTE_WORKER_HOME="$test_root/worker-home" "$worker" once --queue legacy-owner --executor test >"$test_root/runtime-worker.log" ) &
runtime_worker_pid=$!
"$client" invoke tool:runtime-status --json --timeout 20 >"$test_root/runtime-status.json"
wait "$runtime_worker_pid"
ruby -rjson -e 'value=JSON.parse(File.read(ARGV[0])); abort "runtime invocation did not prove Mini execution" unless value["remote_call_succeeded"]==true && value["actual_executor"]=="mac-mini"; abort "runtime schema drift" unless value.dig("output","schema")=="two-head-wu.runtime-status.v1"; catalog=value.dig("output","catalog"); abort "runtime protocol drift" unless catalog["protocol_min"]==2 && catalog["protocol_max"]==2; codex=catalog["runtimes"].find{|item|item["runtime_kind"]=="codex-app-server"}; abort "runtime gate not compatible" unless codex && codex["health"]=="compatible"' "$test_root/runtime-status.json"
( sleep 0.5; WU_REMOTE_WORKER_HOME="$test_root/worker-home" "$worker" once --queue legacy-owner --executor test >"$test_root/catalog-worker.log" ) &
catalog_worker_pid=$!
"$client" invoke tool:module-catalog --json --timeout 20 >"$test_root/module-catalog.json"
wait "$catalog_worker_pid"
ruby -rjson -e 'value=JSON.parse(File.read(ARGV[0])); ids=value.dig("output","adapters").map{|item|item.fetch("capability_id")}; abort "Mini adapter catalog is incomplete" unless ids.include?("tool:codex-status") && ids.include?("tool:runtime-status")' "$test_root/module-catalog.json"

# Newly opened owner-only adapters use the same signed queue and return only structured data.
for capability_id in tool:identity-catalog tool:resource-catalog mcp-tool:openai-docs; do
  safe_name=${capability_id//:/-}
  input='{}'
  [[ "$capability_id" == "mcp-tool:openai-docs" ]] && input='{"action":"search","query":"Codex resume","limit":1}'
  ( sleep 0.5; WU_REMOTE_WORKER_HOME="$test_root/worker-home" "$worker" once --queue legacy-owner --executor test >"$test_root/$safe_name-worker.log" ) &
  adapter_worker_pid=$!
  "$client" invoke "$capability_id" --input-json "$input" --json --timeout 20 >"$test_root/$safe_name.json"
  wait "$adapter_worker_pid"
  ruby -rjson -e 'value=JSON.parse(File.read(ARGV[0])); abort "adapter did not prove Mini execution" unless value["remote_call_succeeded"]==true && value["actual_executor"]=="mac-mini"; abort "adapter schema missing" if value.dig("output","schema").to_s.empty?' "$test_root/$safe_name.json"
done

# The research provider is reached through exact IDs. Read operations never return local paths; an
# explicitly confirmed export reuses the existing 50 MiB / 14-day artifact relay for one complete file.
research_root="$test_root/research-library"
research_binding="$test_root/research-library-binding.json"
research_source="$test_root/research-source.md"
research_metadata="$test_root/research-metadata.json"
print 'Complete fixture body about archival interfaces and artist records.\n' >"$research_source"
ruby -rjson -e 'File.write(ARGV[0], JSON.generate({"title"=>"Remote Archival Interfaces","kind"=>"article","publication_date"=>"2026-08-01","version_kind"=>"published","creators"=>["Ada Example"],"language"=>"en"})+"\n")' "$research_metadata"
TWO_HEAD_WU_RESEARCH_LIBRARY_ROOT="$research_root" "$project_root/capabilities/research-library/adapters/research-library" --data-root "$research_root" initialize --json >/dev/null
printf '{"schema_version":1,"resource_id":"private-data-service","data_root":"%s"}\n' "$research_root" >"$research_binding"
export WU_RESEARCH_LIBRARY_BINDING_FILE="$research_binding"
TWO_HEAD_WU_RESEARCH_LIBRARY_ROOT="$research_root" "$project_root/capabilities/research-library/adapters/research-library" ingest-file --path "$research_source" --metadata "$research_metadata" --confirmed-relevant --json >"$test_root/research-ingested.json"
research_work_id=$(ruby -rjson -e 'print JSON.parse(File.read(ARGV[0])).dig("data","work_id")' "$test_root/research-ingested.json")
research_original_artifact_id=$(ruby -rjson -e 'print JSON.parse(File.read(ARGV[0])).dig("data","artifact_id")' "$test_root/research-ingested.json")
research_original_sha256=$(ruby -rjson -e 'print JSON.parse(File.read(ARGV[0])).dig("data","sha256")' "$test_root/research-ingested.json")
research_export_input="{\"artifact_id\":\"$research_original_artifact_id\",\"expected_sha256\":\"$research_original_sha256\"}"

( sleep 0.5; TWO_HEAD_WU_RESEARCH_LIBRARY_ROOT="$research_root" WU_REMOTE_WORKER_HOME="$test_root/worker-home" "$worker" once --queue legacy-owner --executor codex >"$test_root/research-search-worker.log" ) &
research_search_worker_pid=$!
"$client" invoke research-library:search --input-json '{"query":"archival interfaces","limit":5}' --json --timeout 20 >"$test_root/research-search.json"
wait "$research_search_worker_pid"
ruby -rjson -e 'value=JSON.parse(File.read(ARGV[0])); root=ARGV[1]; work=ARGV[2]; abort "research search did not run on Mini" unless value["remote_call_succeeded"]==true && value["actual_executor"]=="mac-mini"; output=value.fetch("output"); abort "research search schema drift" unless output["schema"]=="two-head-wu.research-library.search.v1" && output.dig("results",0,"work_id")==work; abort "research search leaked a local path" if File.read(ARGV[0]).include?(root)' "$test_root/research-search.json" "$research_root" "$research_work_id"

( sleep 0.5; TWO_HEAD_WU_RESEARCH_LIBRARY_ROOT="$research_root" WU_REMOTE_WORKER_HOME="$test_root/worker-home" "$worker" once --queue legacy-owner --executor codex >"$test_root/research-get-worker.log" ) &
research_get_worker_pid=$!
"$client" invoke research-library:get --input-json "{\"work_id\":\"$research_work_id\"}" --json --timeout 20 >"$test_root/research-get.json"
wait "$research_get_worker_pid"
ruby -rjson -e 'value=JSON.parse(File.read(ARGV[0])); root=ARGV[1]; abort "research get schema drift" unless value.dig("output","schema")=="two-head-wu.research-library.get.v1"; abort "research get leaked a local path" if File.read(ARGV[0]).include?(root) || value.dig("output","document").key?("artifact_path")' "$test_root/research-get.json" "$research_root"

if "$client" invoke research-library:export --input-json "$research_export_input" --wait >"$test_root/research-export-unconfirmed.out" 2>"$test_root/research-export-unconfirmed.err"; then
  print -u2 -- "research artifact export ran without owner confirmation"
  exit 1
fi
rg -q "需要所有者明确确认" "$test_root/research-export-unconfirmed.out"
( sleep 0.5; TWO_HEAD_WU_RESEARCH_LIBRARY_ROOT="$research_root" WU_REMOTE_WORKER_HOME="$test_root/worker-home" "$worker" once --queue legacy-owner --executor codex >"$test_root/research-export-worker.log" ) &
research_export_worker_pid=$!
"$client" invoke research-library:export --input-json "$research_export_input" --confirm --wait --json --timeout 20 >"$test_root/research-export.json"
wait "$research_export_worker_pid"
research_artifact_id=$(ruby -rjson -e 'value=JSON.parse(File.read(ARGV[0])); abort "research export did not use artifact relay" unless value["remote_call_succeeded"]==true && value.dig("output","schema")=="two-head-wu.research-library.export.v1"; artifact=value.dig("output","artifact"); abort "research output artifact is invalid" unless artifact && artifact["id"].match?(/\Aart-[a-f0-9]{24}\z/) && artifact["size"]>0; print artifact["id"]' "$test_root/research-export.json")
research_download=$($client artifacts fetch "$research_artifact_id")
cmp "$research_source" "$research_download"
research_export_job=$(ruby -rjson -e 'print JSON.parse(File.read(ARGV[0])).fetch("job_id")' "$test_root/research-export.json")
"$client" jobs status "$research_export_job" | ruby -rjson -e 'job=JSON.parse(STDIN.read).fetch("job"); abort "research output artifact was not attached to its job" unless job.fetch("output_artifact_ids")==[ARGV[0]]' "$research_artifact_id"
"$client" artifacts remove "$research_artifact_id" >/dev/null

if "$client" invoke workflow:refresh-documentation --wait >"$test_root/workflow-confirm.out" 2>"$test_root/workflow-confirm.err"; then
  print -u2 -- "write workflow ran without owner confirmation"
  exit 1
fi
rg -q "需要所有者明确确认" "$test_root/workflow-confirm.out"
( sleep 0.5; WU_REMOTE_WORKER_HOME="$test_root/worker-home" "$worker" once --queue legacy-owner --executor test >"$test_root/workflow-worker.log" ) &
workflow_worker_pid=$!
"$client" invoke workflow:refresh-documentation --confirm --wait --json --timeout 20 >"$test_root/workflow.json"
wait "$workflow_worker_pid"
ruby -rjson -e 'value=JSON.parse(File.read(ARGV[0])); abort "confirmed workflow did not execute on Mini" unless value["remote_call_succeeded"]==true && value.dig("output","schema")=="two-head-wu.workflow-result.v1"' "$test_root/workflow.json"
( sleep 0.5; WU_REMOTE_WORKER_HOME="$test_root/worker-home" "$worker" once --queue legacy-owner --executor test >"$test_root/air-sync-workflow-worker.log" ) &
air_sync_workflow_worker_pid=$!
"$client" invoke workflow:sync-air --confirm --wait --json --timeout 20 >"$test_root/air-sync-workflow.json"
wait "$air_sync_workflow_worker_pid"
ruby -rjson -e 'value=JSON.parse(File.read(ARGV[0])); abort "Air sync workflow did not execute on Mini" unless value["remote_call_succeeded"]==true && value.dig("output","schema")=="two-head-wu.air-sync.v1" && value.dig("output","status")=="completed"' "$test_root/air-sync-workflow.json"
"$client" devices list | rg -q $'^mac-mini-worker\tmac-mini-worker\tonline\t'
if "$client" devices list | rg -q 'secret|token|Keychain'; then
  print -u2 -- "device directory leaked protected state"
  exit 1
fi

"$client" jobs submit --project "$project" -- "验证离线任务和项目胶囊" >"$test_root/submitted.json"
job_id=$(ruby -rjson -e 'print JSON.parse(File.read(ARGV[0])).fetch("job").fetch("id")' "$test_root/submitted.json")

# The Air side is deliberately idle here. The worker must finish and retain the result on the relay.
WU_REMOTE_WORKER_HOME="$test_root/worker-home" "$worker" once --queue legacy-owner --executor test >/dev/null
"$client" jobs status "$job_id" >"$test_root/status.json"
ruby -rjson -e 'job=JSON.parse(File.read(ARGV[0])).fetch("job"); abort "not succeeded" unless job.fetch("state")=="succeeded"; abort "identity drift" unless job.fetch("identity")=="owner-auto"' "$test_root/status.json"
result_path=$("$client" jobs fetch "$job_id")
test -f "$result_path/final.md"
test -f "$result_path/tests.json"
ruby -rjson -e 'value=JSON.parse(File.read(ARGV[0])); files=value.fetch("workspace_files"); abort "capsule leaked .env" if files.include?(".env"); abort "capsule leaked key" if files.include?("device.key"); abort "capsule leaked dependencies" if files.any?{|path|path.start_with?("node_modules/")}; abort "source missing" unless files.include?("src/input.txt")' "$result_path/tests.json"
"$client" jobs events "$job_id" --after 0 | rg -q 'job.succeeded'

# Air changes made after submission are relayed through the task-scoped project lease and applied before
# the Mini executor observes the workspace.
"$client" jobs submit --project "$project" --project-mode workspace-write -- "验证项目增量桥" >"$test_root/delta-job.json"
delta_job=$(ruby -rjson -e 'print JSON.parse(File.read(ARGV[0])).fetch("job").fetch("id")' "$test_root/delta-job.json")
print 'arrived after submission' >"$project/src/live-added.txt"
"$client" projects sync "$delta_job" | rg -q '"result": "uploaded"'
WU_REMOTE_WORKER_HOME="$test_root/worker-home" "$worker" once --queue legacy-owner --executor test >/dev/null
delta_result=$("$client" jobs fetch "$delta_job")
ruby -rjson -e 'files=JSON.parse(File.read(ARGV[0])).fetch("workspace_files"); abort "project delta did not reach Mini" unless files.include?("src/live-added.txt")' "$delta_result/tests.json"

"$client" jobs submit --project "$project" -- "应该被取消" >"$test_root/cancel.json"
cancel_id=$(ruby -rjson -e 'print JSON.parse(File.read(ARGV[0])).fetch("job").fetch("id")' "$test_root/cancel.json")
"$client" jobs cancel "$cancel_id" >/dev/null
"$client" jobs status "$cancel_id" | rg -q '"state": "cancelled"'
WU_REMOTE_WORKER_HOME="$test_root/worker-home" "$worker" once --queue legacy-owner --executor test | rg -q 'worker queue empty'

if curl --silent --fail "$endpoint/modules" >"$test_root/unauthorized.out" 2>/dev/null; then
  print -u2 -- "unsigned request unexpectedly succeeded"
  exit 1
fi

# A disconnected Air may explain a previously verified directory, but it must not claim cached runtime
# presence is live or silently treat cached remote tools as ready.
cp -R "$test_root/air-home" "$test_root/cache-home"
ruby -rjson -e 'path=ARGV[0]; value=JSON.parse(File.read(path)); value["endpoint"]="http://127.0.0.1:1/two-head-wu/v1"; File.write(path,JSON.pretty_generate(value)+"\n")' "$test_root/cache-home/config.json"
WU_REMOTE_HOME="$test_root/cache-home" "$client" abilities list --json >"$test_root/cached-abilities.json"
ruby -rjson -e '
  value=JSON.parse(File.read(ARGV[0]));
  abort "offline directory did not use verified cache" unless value["directory_source"]=="cache" && value["catalog_signature"]=="verified";
  abort "cached runtime was falsely online" unless value.dig("mini","online").nil?;
  status=value.fetch("remote_capabilities").find{|item|item["id"]=="tool:codex-status"}.fetch("availability");
  abort "cached tool was falsely ready" unless status=="unknown-cached";
  skill=value.dig("mini_inventory","entries").find{|item|item["id"]=="skill:research-survey"};
  abort "cached remote Skill was falsely ready" unless skill && skill["availability"]=="unknown-cached"
' "$test_root/cached-abilities.json"

# Exercise the real guided installer with a fake HOME, mock Keychain, and mock launchctl.
install_token=$(python3 "$server" --root "$test_root/server" issue-enrollment --device owner-air-install --role owner-air --ttl 3600)
export TWO_HEAD_WU_ENROLLMENT_TOKEN="$install_token"
export WU_REMOTE_INSTALLER_ENDPOINT_OVERRIDE="$endpoint"
installer_path=$("$admin" render-installer)
unset TWO_HEAD_WU_ENROLLMENT_TOKEN WU_REMOTE_INSTALLER_ENDPOINT_OVERRIDE
fake_home="$test_root/fake-home"
fake_bin="$test_root/fake-bin"
mkdir -p "$fake_home" "$fake_bin"
cat >"$fake_bin/security" <<'MOCK'
#!/bin/zsh
set -eu
case "$1" in
  add-generic-password)
    secret=""
    while (( $# > 0 )); do
      if [[ "$1" == "-w" ]]; then shift; secret="$1"; break; fi
      shift
    done
    [[ -n "$secret" ]]
    print -rn -- "$secret" >"$HOME/.mock-two-head-wu-keychain"
    ;;
  find-generic-password)
    cat "$HOME/.mock-two-head-wu-keychain"
    ;;
  *) exit 2 ;;
esac
MOCK
cat >"$fake_bin/launchctl" <<'MOCK'
#!/bin/zsh
exit 0
MOCK
cat >"$fake_bin/codex" <<'MOCK'
#!/bin/zsh
set -eu
[[ "$1" == "mcp" ]]
case "$2" in
  get)
    [[ -f "$HOME/.mock-two-head-wu-mcp" ]] || exit 1
    command_path=$(<"$HOME/.mock-two-head-wu-mcp")
    print -r -- "{\"name\":\"two-head-wu\",\"enabled\":true,\"transport\":{\"type\":\"stdio\",\"command\":\"$command_path\",\"args\":[]}}"
    ;;
  add)
    [[ "$3" == "two-head-wu" && "$4" == "--" ]]
    print -rn -- "$5" >"$HOME/.mock-two-head-wu-mcp"
    ;;
  *) exit 2 ;;
esac
MOCK
chmod 755 "$fake_bin/security" "$fake_bin/launchctl" "$fake_bin/codex"
print 'owner-air-install' | env -u WU_REMOTE_HOME -u WU_REMOTE_SKILLS_HOME -u WU_REMOTE_SECRET_STORE HOME="$fake_home" PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" WU_REMOTE_ALLOW_HTTP=1 zsh "$installer_path" >"$test_root/installer.log"
env -u WU_REMOTE_HOME -u WU_REMOTE_SKILLS_HOME -u WU_REMOTE_SECRET_STORE HOME="$fake_home" PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" WU_REMOTE_ALLOW_HTTP=1 "$fake_home/.local/bin/wu" 查看模块 | rg -q '^skill:remote-work'
env -u WU_REMOTE_HOME -u WU_REMOTE_SKILLS_HOME -u WU_REMOTE_SECRET_STORE HOME="$fake_home" PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" WU_REMOTE_ALLOW_HTTP=1 "$fake_home/.local/bin/wu" 查看模型 | rg -q '^fake-model'
env -u WU_REMOTE_HOME -u WU_REMOTE_SKILLS_HOME -u WU_REMOTE_SECRET_STORE HOME="$fake_home" PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" WU_REMOTE_ALLOW_HTTP=1 "$fake_home/.local/bin/wu" 能做什么 --json | ruby -rjson -e 'value=JSON.parse(STDIN.read); abort "installed Air lost dynamic discovery" unless value["catalog_signature"]=="verified"'
test -L "$fake_home/.agents/skills/remote-work"
skill_target=$(readlink "$fake_home/.agents/skills/remote-work")
case "$skill_target" in
  "$fake_home/.config/two-head-wu/remote-work/components/"*) ;;
  *) print -u2 -- "installer skill target escaped managed components: $skill_target"; exit 1 ;;
esac
test -f "$fake_home/Library/LaunchAgents/com.twoheadwu.remote-update.plist"
installed_release=$(readlink "$fake_home/.local/bin/wu")
installed_release=${installed_release%/bin/wu}
test -x "$installed_release/bin/wu-codex-status"
test -x "$installed_release/bin/two-head-wu-mcp"
test -L "$fake_home/.local/bin/wu-codex-status"
test -L "$fake_home/.local/bin/two-head-wu-mcp"
test -f "$fake_home/Library/LaunchAgents/com.twoheadwu.remote-companion.plist"
env -u WU_REMOTE_HOME -u WU_REMOTE_SKILLS_HOME -u WU_REMOTE_SECRET_STORE HOME="$fake_home" PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" WU_REMOTE_ALLOW_HTTP=1 "$fake_home/.local/bin/wu" 查看能力桥 | ruby -rjson -e 'value=JSON.parse(STDIN.read); abort "Codex MCP bridge is unhealthy" unless value["healthy"]==true'
{
  print -r -- '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
  print -r -- '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
  print -r -- '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"two_head_wu_discover","arguments":{"scope":"all"}}}'
} | HOME="$fake_home" "$fake_home/.local/bin/two-head-wu-mcp" >"$test_root/mcp.jsonl"
ruby -rjson -e 'lines=File.readlines(ARGV[0]).map{|line|JSON.parse(line)}; abort "MCP did not initialize" unless lines[0].dig("result","serverInfo","name")=="two-head-wu" && lines[0].dig("result","serverInfo","version")=="0.12.0"; tools=lines[1].dig("result","tools").map{|item|item.fetch("name")}; abort "MCP invoke tool missing" unless tools.include?("two_head_wu_invoke"); inventory=lines[2].dig("result","structuredContent","mini_inventory"); abort "MCP discovery lost complete Mini inventory" unless inventory && inventory["signature"]=="verified" && inventory["total"]==Integer(ARGV[1])' "$test_root/mcp.jsonl" "$expected_inventory_count"
"$fake_home/.local/bin/wu" remote update status | rg -q '"current_release"'
rg -q '^# Two-Headed-Wu user commands$' "$fake_home/.zprofile"
rg -q '^export PATH="\$HOME/\.local/bin:\$PATH"$' "$fake_home/.zprofile"
rg -q '^# Two-Headed-Wu user commands$' "$fake_home/.zshrc"
if ! env -u WU_REMOTE_HOME -u WU_REMOTE_SKILLS_HOME -u WU_REMOTE_SECRET_STORE HOME="$fake_home" PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" WU_REMOTE_ALLOW_HTTP=1 zsh "$installer_path" >"$test_root/installer-rerun.log" 2>&1; then
  sed -n '1,120p' "$test_root/installer-rerun.log"
  exit 1
fi
if ! rg -q '没有重复使用一次性配对凭证' "$test_root/installer-rerun.log"; then
  sed -n '1,120p' "$test_root/installer-rerun.log"
  exit 1
fi

# A normal command checks the selected channel, installs a separately signed release, and transparently
# continues through the new client without contaminating structured stdout.
old_release=$(readlink "$fake_home/.local/bin/wu")
env -u WU_REMOTE_HOME -u WU_REMOTE_SKILLS_HOME -u WU_REMOTE_SECRET_STORE HOME="$fake_home" PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" WU_REMOTE_ALLOW_HTTP=1 "$fake_home/.local/bin/wu" remote update channel dev >/dev/null
( sleep 2; WU_REMOTE_WORKER_HOME="$test_root/worker-home" "$worker" once --queue legacy-owner --executor test >"$test_root/on-use-air-sync-worker.log" ) &
on_use_air_sync_worker_pid=$!
env -u WU_REMOTE_HOME -u WU_REMOTE_SKILLS_HOME -u WU_REMOTE_SECRET_STORE HOME="$fake_home" PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" WU_REMOTE_ALLOW_HTTP=1 WU_REMOTE_ON_USE_UPDATE_INTERVAL_SECONDS=0 "$fake_home/.local/bin/wu" 能做什么 --json >"$test_root/on-use-update.json"
wait "$on_use_air_sync_worker_pid"
new_release=$(readlink "$fake_home/.local/bin/wu")
if [[ "$new_release" == "$old_release" ]]; then
  print -u2 -- "on-use update did not switch the managed client"
  env -u WU_REMOTE_HOME -u WU_REMOTE_SKILLS_HOME -u WU_REMOTE_SECRET_STORE HOME="$fake_home" PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" WU_REMOTE_ALLOW_HTTP=1 "$fake_home/.local/bin/wu" remote update status >&2
  exit 1
fi
test -f "${new_release%/bin/wu}/BUILD_VARIANT"
ruby -rjson -e 'value=JSON.parse(File.read(ARGV[0])); abort "on-use update polluted command output" unless value["catalog_signature"]=="verified"' "$test_root/on-use-update.json"
env -u WU_REMOTE_HOME -u WU_REMOTE_SKILLS_HOME -u WU_REMOTE_SECRET_STORE HOME="$fake_home" PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" WU_REMOTE_ALLOW_HTTP=1 "$fake_home/.local/bin/wu" remote update status >"$test_root/on-use-status.json"
ruby -rjson -e 'value=JSON.parse(File.read(ARGV[0])); state=value.fetch("on_use"); abort "on-use update not enabled" unless state["enabled"]==true; abort "on-use release not recorded" unless state["last_result"]=="updated-pipeline-completed" && state["release_id"]==value["current_release"]; abort "client update did not run Air sync pipeline" unless value.dig("air_sync","status")=="completed"' "$test_root/on-use-status.json"
( sleep 2; WU_REMOTE_WORKER_HOME="$test_root/worker-home" "$worker" once --queue legacy-owner --executor test >"$test_root/explicit-air-sync-worker.log" ) &
explicit_air_sync_worker_pid=$!
env -u WU_REMOTE_HOME -u WU_REMOTE_SKILLS_HOME -u WU_REMOTE_SECRET_STORE HOME="$fake_home" PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" WU_REMOTE_ALLOW_HTTP=1 "$fake_home/.local/bin/wu" 同步两头乌Air >"$test_root/explicit-air-sync.out"
wait "$explicit_air_sync_worker_pid"
rg -q $'^Mini 流水线\t完成\tjob-' "$test_root/explicit-air-sync.out"
rg -q $'^Air 同步\tcompleted$' "$test_root/explicit-air-sync.out"
rg -q "<string>$fake_home/.local/bin/wu</string><string>remote</string><string>update</string><string>all</string>" "$fake_home/Library/LaunchAgents/com.twoheadwu.remote-update.plist"

# A failed use-time check is fail-open: local commands still run on the last healthy signed release.
ruby -rjson -e 'path=ARGV[0]; value=JSON.parse(File.read(path)); value["endpoint"]="http://127.0.0.1:1/two-head-wu/v1"; File.write(path,JSON.pretty_generate(value)+"\n")' "$fake_home/.config/two-head-wu/remote-work/config.json"
rm -f "$fake_home/.config/two-head-wu/remote-work/update-on-use.json"
env -u WU_REMOTE_HOME -u WU_REMOTE_SKILLS_HOME -u WU_REMOTE_SECRET_STORE HOME="$fake_home" PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" WU_REMOTE_ALLOW_HTTP=1 WU_REMOTE_ON_USE_UPDATE_INTERVAL_SECONDS=0 "$fake_home/.local/bin/wu" help | rg -q '两头乌多端工作'
env -u WU_REMOTE_HOME -u WU_REMOTE_SKILLS_HOME -u WU_REMOTE_SECRET_STORE HOME="$fake_home" PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" WU_REMOTE_ALLOW_HTTP=1 "$fake_home/.local/bin/wu" remote update status | ruby -rjson -e 'state=JSON.parse(STDIN.read).fetch("on_use"); abort "failed on-use check was not recorded" unless state["last_result"]=="failed"'

print "remote-work integration tests ok"
