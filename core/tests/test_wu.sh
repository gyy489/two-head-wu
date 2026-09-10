#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
wu="$project_root/core/bin/wu"

"$wu" help | grep -q '^Usage: wu COMMAND'
"$wu" search two-head-wu --json | ruby -rjson -e '
  data = JSON.parse(STDIN.read)
  abort "core package is not searchable" unless data.fetch("results").any? { |item| item["id"] == "two-head-wu-core" }
'
"$wu" resolve --agent two-head-wu --runtime codex --project two-head-wu --json | ruby -rjson -e '
  data = JSON.parse(STDIN.read)
  packages = data.fetch("capability_packages")
  abort "public package count drift" unless packages.length == 10
  abort "duplicate package" unless packages == packages.uniq
  abort "duplicate skill set" unless data.fetch("skill_sets") == data.fetch("skill_sets").uniq
  abort "wrong project" unless data.fetch("project") == "two-head-wu"
'
ruby "$project_root/tools/audit-foundation-platform" >/dev/null

echo "public wu tests ok"
