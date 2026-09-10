#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
adapter="$project_root/capabilities/spec-kit-governance/adapters/spec-kit-governance"
change_adapter="$project_root/capabilities/spec-kit-governance/adapters/change-governance"

test -x "$adapter"
test -x "$change_adapter"

status_output=$("$adapter" status)
printf '%s\n' "$status_output" | grep -q '^spec-kit-governance: '
printf '%s\n' "$status_output" | grep -q '^specify-version: 0\.16\.2$'
printf '%s\n' "$status_output" | grep -q '^default-integration: codex$'
printf '%s\n' "$status_output" | grep -q '^installed-integrations: codex, claude$'

doctor_output=$("$adapter" doctor)
printf '%s\n' "$doctor_output" | grep -q '^spec-kit-governance doctor ok$'

change_output=$("$change_adapter" validate-all)
printf '%s\n' "$change_output" | grep -q '^change governance ok:'

test -f "$project_root/.specify/integrations/codex.manifest.json"
test -f "$project_root/.specify/integrations/claude.manifest.json"
test -f "$project_root/.agents/skills/speckit-specify/SKILL.md"
test -f "$project_root/.claude/skills/speckit-specify/SKILL.md"

if find "$project_root/skills/.active" -maxdepth 2 -name 'speckit-*' -print -quit | grep -q .; then
  echo "Spec Kit project Skill must not be exposed through skills/.active" >&2
  exit 1
fi

echo "spec-kit-governance tests ok"
