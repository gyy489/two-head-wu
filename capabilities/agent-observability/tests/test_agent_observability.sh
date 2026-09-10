#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
adapter="$project_root/capabilities/agent-observability/adapters/agent-observability"
status_data_root=$(mktemp -d "${TMPDIR:-/tmp}/agent-observability-status.XXXXXX")
trap 'rm -rf "$status_data_root"' EXIT

for ruby_source in \
  "$project_root/capabilities/agent-observability/adapters/agent-observability" \
  "$project_root/capabilities/agent-observability/adapters/codex-observed" \
  "$project_root/capabilities/agent-observability/integrations/codex-prelaunch" \
  "$project_root/capabilities/agent-observability/integrations/lazy-otlp-proxy" \
  "$project_root/capabilities/agent-observability/integrations/provider-bootstrap" \
  "$project_root/capabilities/agent-observability/integrations/provider-trigger-broker" \
  "$project_root/capabilities/agent-observability/lib/agent_observability.rb" \
  "$project_root/capabilities/agent-observability/lib/lazy_otlp_proxy.rb"
do
  ruby -c "$ruby_source" >/dev/null
done
"$adapter" help | grep -q 'launch.*identity'
TWO_HEAD_WU_OBSERVABILITY_DATA_ROOT="$status_data_root" "$adapter" status --json | ruby -rjson -e '
  data = JSON.parse(STDIN.read)
  abort "unconfigured status is not truthful" unless data["configured"] == false && data["healthy"] == false
  abort "wrong collection mode" unless data["collection_mode"] == "owner-local-all-codex"
  abort "unconfigured state must not claim persistent config" unless data["persistent_codex_config_changed"] == false
'
ruby "$project_root/capabilities/agent-observability/tests/test_agent_observability.rb"

ruby -ryaml -e '
  compose = YAML.safe_load(File.read(ARGV.fetch(0)), aliases: false)
  services = compose.fetch("services")
  abort "unexpected service count" unless services.keys.sort == %w[clickhouse collector openlit]
  abort "ClickHouse host ports must be absent" if services.fetch("clickhouse").key?("ports")
  ports = services.fetch("openlit").fetch("ports")
  abort "listeners are not loopback-only" unless ports.all? { |item| item.start_with?("127.0.0.1:") }
  abort "mutable latest image is forbidden" if services.values.any? { |item| item.fetch("image").end_with?(":latest") }
' "$project_root/capabilities/agent-observability/deploy/docker-compose.yaml"

ruby -ryaml -e '
  config = YAML.safe_load(File.read(ARGV.fetch(0)), aliases: false)
  pipelines = config.dig("service", "pipelines")
  abort "collector must expose traces only" unless pipelines.keys == ["traces"]
  processors = pipelines.fetch("traces").fetch("processors")
  abort "owner-local filter missing" unless processors.include?("filter/owner_local_codex")
  abort "privacy transform missing" unless processors.include?("transform/privacy")
' "$project_root/capabilities/agent-observability/deploy/otel-collector-config.yaml"
