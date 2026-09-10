#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "pathname"
require "rbconfig"
require "tmpdir"
require "yaml"

require_relative "../lib/agent_observability"
require_relative "../lib/lazy_otlp_proxy"

package = Pathname.new(__dir__).join("..").realpath
manifest = YAML.safe_load(package.join("capability.yaml").read, aliases: false)
abort "wrong package version" unless manifest["version"] == TwoHeadWu::AgentObservability::CAPABILITY_VERSION
abort "package is not executable" unless package.join("adapters/agent-observability").executable?
abort "observed Codex wrapper is not executable" unless package.join("adapters/codex-observed").executable?
manifest_interfaces = manifest.fetch("interfaces").map { |item| item.fetch("id") }
expected_interfaces = ["agent-observability-adapter", *TwoHeadWu::AgentObservability::INTERFACE_COMMANDS.keys]
abort "manifest/interface dispatcher drift" unless manifest_interfaces.sort == expected_interfaces.sort

compose = YAML.safe_load(package.join("deploy/docker-compose.yaml").read, aliases: false)
services = compose.fetch("services")
abort "provider service contract drift" unless services.keys.sort == %w[clickhouse collector openlit]
abort "ClickHouse must not expose a host port" if services.fetch("clickhouse").key?("ports")
host_ports = services.values.flat_map { |service| Array(service["ports"]) }
abort "host listeners must be loopback-only" unless host_ports.all? { |port| port.start_with?("127.0.0.1:") }

collector = YAML.safe_load(package.join("deploy/otel-collector-config.yaml").read, aliases: false)
abort "Collector must be trace-only" unless collector.dig("service", "pipelines").keys == ["traces"]
processors = collector.dig("service", "pipelines", "traces", "processors")
abort "scope filter missing" unless processors.include?("filter/owner_local_codex")
abort "privacy transform missing" unless processors.include?("transform/privacy")
abort "lazy proxy is not executable" unless package.join("integrations/lazy-otlp-proxy").executable?
abort "provider bootstrap is not executable" unless package.join("integrations/provider-bootstrap").executable?
abort "Codex prelaunch hook is not executable" unless package.join("integrations/codex-prelaunch").executable?
abort "provider trigger broker is not executable" unless package.join("integrations/provider-trigger-broker").executable?

ruby_sources = %w[
  adapters/agent-observability
  adapters/codex-observed
  integrations/codex-prelaunch
  integrations/lazy-otlp-proxy
  integrations/provider-bootstrap
  integrations/provider-trigger-broker
  lib/agent_observability.rb
  lib/lazy_otlp_proxy.rb
]
ruby_sources.each do |relative|
  abort "Ruby syntax check failed: #{relative}" unless system(
    RbConfig.ruby, "-c", package.join(relative).to_s, out: File::NULL, err: File::NULL
  )
end

Dir.mktmpdir("agent-observability-release") do |directory|
  project = Pathname.new(directory).join("two-head-wu")
  project.join("var/large-assets").mkpath
  environment = {
    "PATH" => ENV.fetch("PATH", ""),
    "TWO_HEAD_WU_OBSERVABILITY_ALLOW_NON_EXTERNAL_FOR_TEST" => "1"
  }
  instance = TwoHeadWu::AgentObservability.new(
    project_root: project,
    package_root: package,
    environment: environment
  )
  configured = instance.configure
  abort "configure smoke failed" unless configured["configured"] == true
  status = instance.status
  abort "unstarted runtime status is not truthful" unless status["configured"] == true && status["healthy"] == false
end

puts JSON.generate(
  "result" => "ok",
  "capability" => "agent-observability",
  "version" => TwoHeadWu::AgentObservability::CAPABILITY_VERSION,
  "trace_only" => true
)
