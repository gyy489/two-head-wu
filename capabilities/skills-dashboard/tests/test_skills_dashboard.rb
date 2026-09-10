#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "net/http"
require "open3"
require "pathname"
require "tmpdir"

ROOT = Pathname.new(__dir__).join("../../..").expand_path
ADAPTER = ROOT.join("capabilities/skills-dashboard/adapters/skills-dashboard")
require ROOT.join("capabilities/skills-dashboard/server/data_collector").to_s

def run!(*arguments)
  output, error, status = Open3.capture3(ADAPTER.to_s, *arguments)
  raise "#{arguments.join(' ')} failed: #{error}" unless status.success?

  output
end

def fail_run!(*arguments)
  _output, error, status = Open3.capture3(ADAPTER.to_s, *arguments)
  raise "#{arguments.join(' ')} unexpectedly succeeded" if status.success?
  raise "#{arguments.join(' ')} did not report an error" unless error.start_with?("Error:")
end

# --- Part 1: DataCollector, against an isolated fixture project (no dependency on real registry content) ---
Dir.mktmpdir("skills-dashboard-fixture-") do |fixture|
  FileUtils.mkdir_p(File.join(fixture, "skills/registries"))
  FileUtils.mkdir_p(File.join(fixture, "registries"))
  FileUtils.mkdir_p(File.join(fixture, "skills/.active/alpha"))
  FileUtils.mkdir_p(File.join(fixture, "skills/.active/beta"))
  FileUtils.mkdir_p(File.join(fixture, "capabilities/alpha-capability"))

  File.write(File.join(fixture, "skills/registries/skills_registry.yaml"), <<~YAML)
    skills:
      - name: alpha
        category: test/alpha
        provenance: personal
        status: active
        path: "skills/.active/alpha"
        entrypoint: "SKILL.md"
        risk_level: low
        network_access: none
        filesystem_access: read
        purpose: "Alpha test skill."
      - name: beta
        category: test/beta
        provenance: personal
        status: active
        path: "skills/.active/beta"
        entrypoint: "SKILL.md"
        risk_level: low
        network_access: none
        filesystem_access: read
        purpose: "Beta test skill."
  YAML

  File.write(File.join(fixture, "registries/capabilities_registry.yaml"), <<~YAML)
    skill_sets:
      test-set:
        description: "Fixture set."
        skills:
          - alpha
          - beta
        compatibility:
          codex: native
          claude-code: compatible
          openclaw: denied
  YAML

  File.write(File.join(fixture, "capabilities/alpha-capability/capability.yaml"), <<~YAML)
    id: alpha-capability
    version: "0.1.0"
    components:
      skills:
        - "skills/alpha"
    dependencies:
      - id: two-head-wu-core
        version: ">=0.1.0"
  YAML

  File.write(File.join(fixture, "skills/.active/alpha/SKILL.md"), <<~MD)
    ---
    name: alpha
    description: Alpha test skill.
    ---

    # Alpha

    This skill hands follow-up formatting work off to beta when needed.
  MD

  File.write(File.join(fixture, "skills/.active/beta/SKILL.md"), <<~MD)
    ---
    name: beta
    description: Beta test skill.
    ---

    # Beta

    Nothing to see here.
  MD

  data = SkillsDashboard::DataCollector.new(fixture).build
  node_ids = data.fetch("nodes").map { |n| n["id"] }
  raise "skill nodes missing" unless (%w[skill:alpha skill:beta] - node_ids).empty?
  raise "skill_set node missing" unless node_ids.include?("skill_set:test-set")
  raise "capability node missing" unless node_ids.include?("capability:alpha-capability")
  raise "runtime nodes missing" unless (%w[runtime:codex runtime:claude-code runtime:openclaw] - node_ids).empty?

  edges = data.fetch("edges")
  member_edges = edges.select { |e| e["type"] == "member_of" }
  raise "member_of edges wrong" unless member_edges.map { |e| e["source"] }.sort == %w[skill:alpha skill:beta]
  raise "member_of target wrong" unless member_edges.all? { |e| e["target"] == "skill_set:test-set" }

  available = edges.select { |e| e["type"] == "available_to" && e["source"] == "skill:alpha" }
  raise "available_to should include codex and claude-code" unless available.map { |e| e["target"] }.sort == %w[runtime:claude-code runtime:codex]
  raise "available_to must not leak a denied runtime" if available.any? { |e| e["target"] == "runtime:openclaw" }

  owns = edges.find { |e| e["type"] == "owns" }
  raise "owns edge wrong" unless owns && owns["source"] == "capability:alpha-capability" && owns["target"] == "skill:alpha"

  depends = edges.find { |e| e["type"] == "depends_on" }
  raise "depends_on should point at an external node when the dependency isn't a local capability" \
    unless depends && depends["target"] == "external:two-head-wu-core"

  inferred = edges.select { |e| e["type"] == "inferred_uses" }
  raise "inferred_uses should find alpha mentioning beta" \
    unless inferred.any? { |e| e["source"] == "skill:alpha" && e["target"] == "skill:beta" && e["confidence"] == "inferred" }
  raise "inferred_uses must not fabricate a beta -> alpha edge" if inferred.any? { |e| e["source"] == "skill:beta" }
  raise "evidence-backed edges must not be tagged inferred" if (edges - inferred).any? { |e| e["confidence"] == "inferred" }
end

# --- Part 2: adapter CLI lifecycle against the real project (read-only; only var/skills-dashboard/ is touched) ---
# The adapter tracks exactly one running instance globally (var/skills-dashboard/server.json), so if a
# real dashboard is already up (e.g. the user left one running), suspend it for the duration of this
# test and bring it back afterward instead of colliding with it or leaving it down as a side effect.
prior_status = JSON.parse(run!("status", "--json"))
was_running_before = prior_status.fetch("running")
prior_port = prior_status["port"]
Open3.capture3(ADAPTER.to_s, "stop") if was_running_before

test_port = 18234
begin
  started = run!("start", "--port", test_port.to_s)
  raise "start did not report success" unless started.include?("result: started") && started.include?("port: #{test_port}")

  status = JSON.parse(run!("status", "--json"))
  raise "status should report running" unless status.fetch("running") == true
  raise "status port mismatch" unless status.fetch("port") == test_port

  graph_response = Net::HTTP.get_response(URI("http://127.0.0.1:#{test_port}/api/graph"))
  raise "graph endpoint did not return 200" unless graph_response.code == "200"
  raise "graph endpoint must not send a CORS header" if graph_response["Access-Control-Allow-Origin"]
  graph = JSON.parse(graph_response.body)
  raise "graph has no skill nodes" unless graph.fetch("nodes").any? { |n| n["kind"] == "skill" }
  raise "graph has no edges" if graph.fetch("edges").empty?

  health = JSON.parse(Net::HTTP.get(URI("http://127.0.0.1:#{test_port}/api/health")))
  raise "health check failed" unless health.fetch("status") == "ok"

  index = Net::HTTP.get(URI("http://127.0.0.1:#{test_port}/")).force_encoding("UTF-8")
  raise "index page missing expected title" unless index.include?("Skills 拓扑")

  double_start = run!("start", "--port", test_port.to_s)
  raise "starting while already running should say so, not start a second instance" unless double_start.include?("already-running")

  Open3.capture3(ADAPTER.to_s, "stop")
  after_stop = JSON.parse(run!("status", "--json"))
  raise "status should report not running after stop" if after_stop.fetch("running")
  fail_run!("stop")

  # --- Part 3: idle auto-shutdown, the reason this dashboard doesn't need to run as a standing service ---
  def alive?(port)
    Net::HTTP.get_response(URI("http://127.0.0.1:#{port}/api/health")).code == "200"
  rescue Errno::ECONNREFUSED
    false
  end

  idle_port = 18235
  idle_started = run!("start", "--port", idle_port.to_s, "--idle-timeout", "3")
  raise "idle-timeout start did not report success" unless idle_started.include?("result: started") && idle_started.include?("idle_timeout: 3")

  sleep 1.5
  raise "server should still be alive well within the idle timeout" unless alive?(idle_port)

  sleep 2 # ~2s since the request above, still under the 3s idle window -- proves a request resets the clock
  raise "a request partway through the window should have reset the idle clock" unless alive?(idle_port)

  sleep 6 # comfortably past idle_timeout + the monitor's check interval, with no further activity
  idle_status = JSON.parse(run!("status", "--json"))
  raise "server should have self-shut-down after sitting idle past --idle-timeout" if idle_status.fetch("running")
  state_file = ROOT.join("var/skills-dashboard/server.json")
  raise "idle self-shutdown should have deleted its own pid/port state file" if state_file.exist?
ensure
  # Always tear down the test instance, then always try to bring back whatever was running
  # before this test started -- both must run even if an assertion above raised.
  Open3.capture3(ADAPTER.to_s, "stop")
  Open3.capture3(ADAPTER.to_s, "start", "--port", prior_port.to_s) if was_running_before
end

puts "skills-dashboard tests ok"
