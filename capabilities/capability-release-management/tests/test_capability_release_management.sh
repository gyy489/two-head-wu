#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
adapter="$project_root/capabilities/capability-release-management/adapters/capability-release-manager"

ruby -c "$project_root/capabilities/capability-release-management/lib/capability_release_manager.rb" >/dev/null
ruby -c "$adapter" >/dev/null
"$adapter" help | grep -q 'update.*--automatic'
"$adapter" status --project two-head-wu --json | ruby -rjson -e '
  data = JSON.parse(STDIN.read)
  bindings = data.fetch("bindings")
  abort "project capability bindings are incomplete" unless bindings.map { |item| item.fetch("capability") }.sort == %w[agent-observability local-translation personal-memory research-ingestion research-library]
  policies = bindings.to_h { |item| [item.fetch("capability"), item.fetch("policy")] }
  abort "project capability policies are invalid" unless policies == {
    "agent-observability" => "pinned", "local-translation" => "pinned", "personal-memory" => "pinned",
    "research-ingestion" => "compatible", "research-library" => "compatible"
  } && bindings.all? { |item| item.fetch("automatic") == false }
'
ruby "$project_root/capabilities/capability-release-management/tests/test_capability_release_manager.rb"
