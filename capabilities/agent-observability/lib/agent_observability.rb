# frozen_string_literal: true

require "cgi"
require "digest"
require "fileutils"
require "json"
require "net/http"
require "open3"
require "optparse"
require "pathname"
require "securerandom"
require "socket"
require "time"
require "timeout"
require "yaml"

module TwoHeadWu
  class AgentObservability
    class Error < StandardError; end

    SCHEMA_VERSION = 3
    CAPABILITY_VERSION = "0.3.11"
    PROJECT_ID = "two-head-wu"
    LOGICAL_IDENTITY = "two-head-wu-codex"
    RUNTIME_ID = "codex"
    RUNTIME_SURFACE = "owner-local-codex"
    FRONTEND_PORT = 4318
    BACKEND_PORT = 4319
    LAUNCH_AGENT_LABEL = "com.twoheadwu.agent-observability"
    CONFIG_MARKER_BEGIN = "# BEGIN TWO-HEAD-WU AGENT OBSERVABILITY (managed)"
    CONFIG_MARKER_END = "# END TWO-HEAD-WU AGENT OBSERVABILITY (managed)"
    WRAPPER_MARKER_BEGIN = "# BEGIN TWO-HEAD-WU AGENT OBSERVABILITY PRELAUNCH (managed)"
    WRAPPER_MARKER_END = "# END TWO-HEAD-WU AGENT OBSERVABILITY PRELAUNCH (managed)"
    PROFILE = "ltw-ao"
    OPENLIT_VERSION = "2.0.0"
    OPENLIT_IMAGE = "ghcr.io/openlit/openlit@sha256:13369868868680efee0fbbdf6a109b8229a364f02e3310ce28a0c6cd95f149e2"
    CLICKHOUSE_VERSION = "24.4.1"
    CLICKHOUSE_IMAGE = "clickhouse/clickhouse-server@sha256:4b14982a78c47d9ecc76ac3b13a0bfd2a31eed1f486fff6e944bcc5e08da2da9"
    RETENTION_HOURS = 2_190
    MAX_QUERY_DAYS = 366
    DEFAULT_QUERY_DAYS = 30
    DEFAULT_QUERY_LIMIT = 100
    COLIMA_CPUS = 2
    COLIMA_MEMORY_GIB = 4
    COLIMA_DISK_GIB = 100
    COMMAND_TIMEOUT_SECONDS = 10
    REQUIRED_COMMANDS = %w[codex colima docker].freeze
    RUNTIME_BUNDLE_FILES = %w[
      adapters/agent-observability
      adapters/codex-observed
      integrations/codex-prelaunch
      integrations/lazy-otlp-proxy
      integrations/provider-bootstrap
      integrations/provider-trigger-broker
      lib/agent_observability.rb
      lib/lazy_otlp_proxy.rb
      deploy/docker-compose.yaml
      deploy/otel-collector-config.yaml
      deploy/clickhouse-config.xml
      deploy/clickhouse-init.sh
      capability.yaml
    ].freeze
    RUNTIME_EXECUTABLES = %w[
      adapters/agent-observability
      adapters/codex-observed
      integrations/codex-prelaunch
      integrations/lazy-otlp-proxy
      integrations/provider-bootstrap
      integrations/provider-trigger-broker
    ].freeze
    INTERFACE_COMMANDS = {
      "agent-observability.configure.v1" => "configure",
      "agent-observability.start.v1" => "start",
      "agent-observability.stop.v1" => "stop",
      "agent-observability.status.v1" => "status",
      "agent-observability.coverage.v1" => "coverage",
      "agent-observability.query.v1" => "query",
      "agent-observability.launch.v1" => "launch",
      "agent-observability.install.v1" => "install",
      "agent-observability.uninstall.v1" => "uninstall",
      "agent-observability.verify.v1" => "verify"
    }.freeze

    Result = Struct.new(:stdout, :stderr, :status, keyword_init: true) do
      def success?
        status.to_i.zero?
      end
    end

    class Runner
      def capture(environment, *command, stdin_data: "", timeout_seconds: nil)
        return capture_bounded(environment, command, stdin_data, timeout_seconds) if timeout_seconds

        stdout, stderr, status = Open3.capture3(environment, *command, stdin_data: stdin_data)
        Result.new(stdout: stdout, stderr: stderr, status: status.exitstatus)
      rescue Errno::ENOENT => error
        Result.new(stdout: "", stderr: error.message, status: 127)
      end

      private

      def capture_bounded(environment, command, stdin_data, timeout_seconds)
        Open3.popen3(environment, *command, pgroup: true) do |stdin, stdout, stderr, wait_thread|
          stdin.write(stdin_data)
          stdin.close
          stdout_reader = Thread.new { stdout.read }
          stderr_reader = Thread.new { stderr.read }
          unless wait_thread.join(timeout_seconds)
            terminate_group(wait_thread.pid, wait_thread)
            return Result.new(
              stdout: stdout_reader.value,
              stderr: [stderr_reader.value, "command timed out after #{timeout_seconds} seconds"].reject(&:empty?).join("\n"),
              status: 124
            )
          end

          Result.new(stdout: stdout_reader.value, stderr: stderr_reader.value, status: wait_thread.value.exitstatus)
        end
      rescue Errno::ENOENT => error
        Result.new(stdout: "", stderr: error.message, status: 127)
      end

      def terminate_group(pid, wait_thread)
        Process.kill("TERM", -pid)
        return if wait_thread.join(2)

        Process.kill("KILL", -pid)
        wait_thread.join(2)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end
    end

    attr_reader :project_root, :package_root, :data_root, :colima_home

    def initialize(project_root: nil, data_root: nil, package_root: nil, runner: Runner.new, environment: ENV)
      @environment = environment
      @package_root = Pathname.new(package_root || Pathname.new(__dir__).join("..")).expand_path.cleanpath
      @project_root = resolve_project_root(project_root)
      @colima_home = default_colima_home
      @data_root = Pathname.new(
        data_root || environment["TWO_HEAD_WU_OBSERVABILITY_DATA_ROOT"] ||
        default_data_root
      ).expand_path.cleanpath
      @runner = runner
    end

    def configure
      with_integration_mutation_lock { configure_without_lock }
    end

    def configure_without_lock
      verify_external_project_root!
      verify_confined_data_root!
      verify_no_symlink_ancestors!(@data_root)
      verify_no_symlink_ancestors!(@colima_home)

      [@data_root, clickhouse_data_root, openlit_data_root, runtime_config_root,
       @colima_home, colima_cache_home].each { |path| FileUtils.mkdir_p(path, mode: 0o700) }
      [@data_root, runtime_config_root].each { |path| FileUtils.chmod(0o700, path) }

      created_secret = ensure_environment_file!

      atomic_write(
        runtime_manifest,
        JSON.pretty_generate(runtime_contract.merge("configured_at" => Time.now.utc.iso8601)) + "\n",
        mode: 0o600
      )
      {
        "result" => "configured",
        "configured" => true,
        "created_secret" => created_secret,
        "project" => PROJECT_ID,
        "logical_identity" => LOGICAL_IDENTITY,
        "data_root" => @data_root.to_s,
        "external_volume" => external_volume?,
        "retention_hours" => RETENTION_HOURS,
        "persistent_codex_config_changed" => integration_state_file.file?
      }
    end

    def install
      with_integration_mutation_lock { install_without_lock }
    end

    def install_without_lock
      require_configured!
      homes = registered_identity_homes
      raise Error, "agent-identity returned no configured Codex homes" if homes.empty?

      state = load_integration_state
      state["schema_version"] = 1
      state["homes"] ||= {}
      snapshots = installation_snapshots(homes, state)
      launch_agent_was_loaded = launch_agent_loaded?
      desired_keys = homes.map { |home| home_state_key(home) }
      stale_keys = state.fetch("homes").keys - desired_keys
      stale_plans = stale_keys.map do |key|
        restore_plan(state.fetch("homes").fetch(key), allow_previous_managed_version: true)
      end

      begin
        install_runtime_bundle!
        stale_plans.each do |plan|
          atomic_write(plan.fetch("path"), plan.fetch("restored"), mode: plan.fetch("mode"))
        end
        stale_keys.each { |key| state.fetch("homes").delete(key) }
        homes.each do |home|
          install_codex_home!(home, state)
        end
        install_launch_surfaces!(state)
        state["installed_at"] = Time.now.utc.iso8601
        atomic_write(integration_state_file, JSON.pretty_generate(state) + "\n", mode: 0o600)
        write_verification_marker if state.dig("verification", "state") == "active"
        install_launch_agent!
      rescue StandardError => error
        rollback_errors = rollback_installation(snapshots, launch_agent_was_loaded: launch_agent_was_loaded)
        unless rollback_errors.empty?
          raise Error, "#{error.message}; installation rollback failed: #{rollback_errors.join('; ')}"
        end
        raise
      end

      integration_status.merge("result" => "installed")
    end

    def uninstall
      with_integration_mutation_lock { uninstall_without_lock }
    end

    def uninstall_without_lock
      raise Error, "agent-observability integration is not installed" unless integration_state_file.file?

      state = load_integration_state
      home_plans = Array(state.fetch("homes", {}).values).map { |entry| restore_plan(entry) }
      plans = home_plans + launch_surface_restore_plans(state)
      changed = []
      begin
        plans.each do |plan|
          atomic_write(plan.fetch("path"), plan.fetch("restored"), mode: plan.fetch("mode"))
          changed << plan
        end
        unload_launch_agent!
        FileUtils.rm_f(launch_agent_file)
      rescue StandardError
        changed.reverse_each do |plan|
          atomic_write(plan.fetch("path"), plan.fetch("original"), mode: plan.fetch("mode"))
        rescue StandardError
          nil
        end
        raise
      end
      FileUtils.rm_f(integration_state_file)
      {
        "result" => "uninstalled",
        "provider_data_preserved" => true,
        "codex_homes_restored" => home_plans.length,
        "launch_surfaces_restored" => plans.length - home_plans.length,
        "launch_agent_removed" => !launch_agent_file.exist?,
        "recovery_state_removed" => true
      }
    end

    def verify(project_id:, conversation_id:)
      with_integration_mutation_lock do
        verify_without_lock(project_id: project_id, conversation_id: conversation_id)
      end
    end

    def verify_without_lock(project_id:, conversation_id:)
      raise Error, "invalid verification project id" unless safe_project_id(project_id)
      unless conversation_id.to_s.match?(/\A[0-9a-f-]{20,64}\z/i)
        raise Error, "invalid verification conversation id"
      end
      current = status
      raise Error, "agent-observability is not healthy" unless current["healthy"]
      raise Error, "privacy verification failed" unless current.dig("privacy", "passed") == true

      identities = identity_status.fetch("identities", []).count { |item| item["configured"] == true }
      integration = integration_status
      unless integration["installed"] && integration["configured_home_count"] == identities
        raise Error, "Codex identity integration is incomplete"
      end
      evidence = verification_evidence(project_id, conversation_id)
      raise Error, "no completed real Codex token trace is mapped to #{project_id}" unless evidence["verified"]

      state = load_integration_state
      previous_verification = state["verification"] || {}
      verified_at = Time.now.utc.iso8601
      history = verification_history
      activated_at = previous_verification["activated_at"] || previous_verification["verified_at"] ||
                     history["activated_at"] || history["verified_at"] || verified_at
      state["verification"] = {
        "state" => "active",
        "activated_at" => activated_at,
        "verified_at" => verified_at,
        "project_id" => project_id,
        "conversation_id" => conversation_id,
        "conversation_count" => evidence.fetch("conversation_count"),
        "token_observations" => evidence.fetch("token_observations")
      }
      atomic_write(integration_state_file, JSON.pretty_generate(state) + "\n", mode: 0o600)
      write_verification_marker
      { "result" => "verified", "evidence" => evidence, "commissioning_gaps_preserved" => all_coverage_gaps.count }
    end

    private :configure_without_lock, :install_without_lock, :uninstall_without_lock, :verify_without_lock

    def start(wait_seconds: 240, pull: true)
      with_local_state_lock("provider-lifecycle.lock", nonblocking: true) do
        start_without_lock(wait_seconds: wait_seconds, pull: pull)
      end
    end

    def start_without_lock(wait_seconds:, pull:)
      require_configured!
      require_commands!
      start_colima!
      wait_for_docker!(60)
      require_compose!
      validate_provider_configuration!
      arguments = ["up", "-d"]
      arguments.concat(["--pull", "always"]) if pull
      arguments << "--remove-orphans"
      compose!(*arguments, timeout_seconds: 900)
      wait_for_health!(wait_seconds)
      status
    end

    def stop
      return unconfigured_status.merge("result" => "stopped") unless configured?

      with_local_state_lock("provider-lifecycle.lock", nonblocking: true) { stop_without_lock }
    end

    def stop_without_lock
      stop_proxy_process!
      if colima_running?
        compose_error = nil
        begin
          compose!("down", "--remove-orphans", timeout_seconds: 180)
        rescue Error => error
          compose_error = error
        ensure
          run_colima!("stop", PROFILE, timeout_seconds: 180)
        end
        raise compose_error if compose_error
      end
      status.merge("result" => "stopped", "data_preserved" => true)
    end

    private :start_without_lock, :stop_without_lock

    def status
      return unconfigured_status unless configured?

      colima = command_available?("colima") && colima_running?
      compose_available = colima && compose_command
      services = compose_available ? compose_service_states : {}
      ui = services["openlit"] == "healthy" && tcp_open?("127.0.0.1", 3000)
      otlp = services["collector"] == "healthy" && otlp_backend_ready?
      trace_rows = nil
      log_rows = nil
      privacy = nil
      if services["clickhouse"] == "healthy"
        counts = database_counts
        trace_rows = counts["traces"]
        log_rows = counts["logs"]
        privacy = database_privacy_counts
      end

      integration = integration_status
      database_healthy = !trace_rows.nil? && !log_rows.nil?
      privacy_healthy = privacy.is_a?(Hash) && privacy["passed"] == true
      provider_healthy = colima && services["clickhouse"] == "healthy" &&
        services["openlit"] == "healthy" && services["collector"] == "healthy" &&
        ui && otlp && database_healthy
      {
        "result" => "status",
        "configured" => true,
        "healthy" => provider_healthy && privacy_healthy && integration.fetch("installed"),
        "provider_healthy" => provider_healthy,
        "database_healthy" => database_healthy,
        "privacy_healthy" => privacy_healthy,
        "project" => PROJECT_ID,
        "logical_identity" => LOGICAL_IDENTITY,
        "collection_mode" => "owner-local-all-codex",
        "trace_only" => true,
        "persistent_codex_config_changed" => integration_state_file.file?,
        "external_volume" => external_volume?,
        "data_root" => @data_root.to_s,
        "retention_hours" => RETENTION_HOURS,
        "provider" => {
          "openlit" => OPENLIT_VERSION,
          "clickhouse" => CLICKHOUSE_VERSION
        },
        "runtime" => {
          "colima" => colima ? "running" : "stopped",
          "compose" => compose_available ? "available" : "unavailable",
          "services" => services
        },
        "integration" => integration,
        "endpoints" => {
          "ui" => ui ? "http://127.0.0.1:3000" : nil,
          "otlp_http_backend" => otlp ? "http://127.0.0.1:#{BACKEND_PORT}" : nil,
          "otlp_http_frontend" => integration.fetch("launch_agent_loaded") &&
            integration.fetch("launch_agent_current") ? "http://127.0.0.1:#{FRONTEND_PORT}" : nil,
          "clickhouse_host_port" => nil
        },
        "stored" => {
          "trace_rows" => trace_rows,
          "codex_log_rows" => log_rows
        },
        "privacy" => privacy
      }
    end

    def coverage
      identities = identity_status
      registered = Array(identities["identities"])
      configured = registered.count { |item| item["configured"] == true }
      integration = integration_status
      gaps = recent_coverage_gaps(phase: "production")
      commissioning_gaps = recent_coverage_gaps(phase: "commissioning")
      {
        "result" => "coverage",
        "scope" => "owner-local-mac",
        "logical_identity" => LOGICAL_IDENTITY,
        "identity_dimension_stored" => false,
        "registered_identity_count" => registered.length,
        "selectable_identity_count" => configured,
        "persistent_home_configuration_count" => integration.fetch("configured_home_count"),
        "launch_agent_loaded" => integration.fetch("launch_agent_loaded"),
        "coverage_mode" => "all-registered-local-identities",
        "launch_surfaces" => %w[terminal codex-as vscode managed-terminal],
        "coverage_complete" => integration.fetch("installed") &&
          integration.fetch("configured_home_count") == configured && gaps.empty?,
        "recent_gap_count" => gaps.length,
        "recent_gaps" => gaps,
        "commissioning_gap_count" => commissioning_gaps.length,
        "commissioning_gaps_affect_coverage" => false,
        "warning" => if configured.zero?
                       "No configured Codex identities were reported by agent-identity."
                     elsif !integration.fetch("installed")
                       "Global Codex observability integration is not installed."
                     elsif integration.fetch("configured_home_count") != configured
                       "A registered Codex identity is not integrated; rerun install."
                     elsif gaps.any?
                       "Recent trace-safe coverage gaps are present."
                     end
      }
    end

    def integration_status
      state = load_integration_state
      configured_home_paths = state.fetch("homes", {}).values.each_with_object([]) do |entry, output|
        config_path = Pathname.new(entry.fetch("config_path", ""))
        content = config_path.file? ? config_path.read : ""
        if content.include?(CONFIG_MARKER_BEGIN) &&
           content.include?(managed_notify_token(entry.fetch("state_key", "")))
          output << config_path.expand_path.cleanpath.to_s
        end
      rescue Errno::EACCES, Errno::ENOENT
        nil
      end
      registered_config_paths = registered_identity_homes.map do |home|
        Pathname.new(home).join("config.toml").expand_path.cleanpath.to_s
      end.uniq.sort
      launch_surfaces_configured = launch_surface_restore_plans(state).length == 2
      launch_agent_current = launch_agent_current?
      launch_agent_loaded = launch_agent_loaded?
      runtime_bundle_current = runtime_bundle_current?
      {
        "result" => "integration-status",
        "installed" => integration_state_file.file? && runtime_bundle_current && launch_agent_current &&
          launch_agent_loaded && launch_surfaces_configured &&
          configured_home_paths.sort == registered_config_paths,
        "configured_home_count" => configured_home_paths.length,
        "runtime_bundle_current" => runtime_bundle_current,
        "launch_surfaces_configured" => launch_surfaces_configured,
        "launch_agent_file" => launch_agent_file.file?,
        "launch_agent_current" => launch_agent_current,
        "launch_agent_loaded" => launch_agent_loaded,
        "provider_start_policy" => "first-telemetry-start-and-buffer;turn-notify-redundant",
        "verification_state" => state.dig("verification", "state") || "commissioning",
        "run_at_load" => false,
        "frontend_port" => FRONTEND_PORT,
        "backend_port" => BACKEND_PORT
      }
    rescue Error, KeyError, TypeError, ArgumentError
      {
        "result" => "integration-status",
        "installed" => false,
        "configured_home_count" => configured_home_paths&.length || 0,
        "runtime_bundle_current" => runtime_bundle_current?,
        "launch_surfaces_configured" => false,
        "launch_agent_file" => launch_agent_file.file?,
        "launch_agent_current" => launch_agent_current?,
        "launch_agent_loaded" => launch_agent_loaded?,
        "provider_start_policy" => "first-telemetry-start-and-buffer;turn-notify-redundant",
        "verification_state" => state&.dig("verification", "state") || "commissioning",
        "run_at_load" => false,
        "frontend_port" => FRONTEND_PORT,
        "backend_port" => BACKEND_PORT
      }
    end

    def query(days: DEFAULT_QUERY_DAYS, group_by: "summary", limit: DEFAULT_QUERY_LIMIT)
      require_healthy!
      days = Integer(days)
      limit = Integer(limit)
      raise Error, "days must be between 1 and #{MAX_QUERY_DAYS}" unless days.between?(1, MAX_QUERY_DAYS)
      raise Error, "limit must be between 1 and 500" unless limit.between?(1, 500)
      raise Error, "unsupported grouping: #{group_by}" unless %w[summary day project model tool capability surface].include?(group_by)

      rows = case group_by
             when "summary" then query_summary(days)
             when "day" then query_tokens(days, "toDate(Timestamp)", "day", limit)
             when "project" then query_projects(days, limit)
             when "model" then query_models(days, limit)
             when "tool" then query_tools(days, limit)
             when "capability" then query_capabilities(days, limit)
             when "surface" then query_surfaces(days, limit)
             end
      {
        "result" => "query",
        "scope" => "owner-local-mac",
        "logical_identity" => LOGICAL_IDENTITY,
        "days" => days,
        "group_by" => group_by,
        "facts" => rows,
        "classification" => "direct-aggregate",
        "not_claimed" => [
          "semantic work phase", "feature outcome", "subscription cost", "Skill use",
          "token allocation to an individual Capability"
        ]
      }
    rescue ArgumentError
      raise Error, "days and limit must be integers"
    end

    def launch(identity: nil, codex_arguments: [])
      validate_codex_arguments!(codex_arguments)
      identity ||= project_default_identity
      raise Error, "no registered identity is bound to project #{PROJECT_ID}" if identity.to_s.empty?

      home = identity_home(identity)
      codex = command_path("codex")
      raise Error, "codex command is unavailable" unless codex

      command = [
        codex,
        "-C", @project_root.to_s,
        "-c", codex_otel_override,
        *codex_arguments
      ]
      launch_environment = {
        "CODEX_HOME" => home,
        "TWO_HEAD_WU_OBSERVED_PROJECT" => PROJECT_ID
      }
      exec(launch_environment, *command)
    end

    def handle_notify(state_key:, payload_text:)
      payload = JSON.parse(payload_text)
      raise Error, "Codex notify payload must be an object" unless payload.is_a?(Hash)

      request_provider_start
      conversation_id = notify_value(
        payload, "thread-id", "thread_id", "conversation-id", "conversation_id", "session-id", "session_id"
      )
      project = notify_project(payload)
      if conversation_id.to_s.empty?
        record_coverage_gap("notify-missing-conversation", project_id: project.fetch("id"))
      else
        send_project_mapping(conversation_id.to_s, project)
      end
      {
        "result" => "notify-processed",
        "project_id" => project.fetch("id"),
        "mapped" => !conversation_id.to_s.empty?
      }
    rescue JSON::ParserError
      record_coverage_gap("notify-invalid-json")
      raise Error, "Codex notify payload is invalid JSON"
    ensure
      forward_previous_notify(state_key, payload_text)
    end

    def record_coverage_gap(reason, project_id: "local-unclassified", bytes: nil, phase: nil)
      allowed = %w[
        notify-invalid-json notify-missing-conversation frontend-unavailable queue-full
        provider-start-failed backend-forward-failed invalid-otlp-request
        proxy-start-failed proxy-worker-failed notify-missing-project frontend-overloaded
      ]
      reason = "invalid-otlp-request" unless allowed.include?(reason)
      row = {
        "timestamp" => Time.now.utc.iso8601,
        "reason" => reason,
        "phase" => phase || (integration_verified? ? "production" : "commissioning"),
        "project_id" => safe_project_id(project_id) ? project_id : "local-unclassified"
      }
      row["bytes"] = Integer(bytes) if bytes
      FileUtils.mkdir_p(coverage_gap_file.dirname, mode: 0o700)
      File.open(coverage_gap_file, File::WRONLY | File::APPEND | File::CREAT, 0o600) do |file|
        file.flock(File::LOCK_EX)
        file.puts(JSON.generate(row))
      end
      FileUtils.chmod(0o600, coverage_gap_file)
      row
    rescue ArgumentError, TypeError, SystemCallError, IOError
      nil
    end

    def runtime_contract
      {
        "schema_version" => SCHEMA_VERSION,
        "capability" => "agent-observability",
        "capability_version" => CAPABILITY_VERSION,
        "scope" => "owner-local-mac",
        "project" => PROJECT_ID,
        "project_root" => @project_root.to_s,
        "logical_identity" => LOGICAL_IDENTITY,
        "data_root" => @data_root.to_s,
        "colima_home" => @colima_home.to_s,
        "colima_profile" => PROFILE,
        "docker_host" => "unix://#{docker_socket_path}",
        "trace_only" => true,
        "frontend_port" => FRONTEND_PORT,
        "backend_port" => BACKEND_PORT,
        "retention_hours" => RETENTION_HOURS,
        "openlit_version" => OPENLIT_VERSION,
        "openlit_image" => OPENLIT_IMAGE,
        "clickhouse_version" => CLICKHOUSE_VERSION,
        "clickhouse_image" => CLICKHOUSE_IMAGE,
        "resource_limits" => {
          "cpus" => COLIMA_CPUS,
          "memory_gib" => COLIMA_MEMORY_GIB,
          "disk_gib" => COLIMA_DISK_GIB
        }
      }
    end

    private

    def resolve_project_root(explicit)
      value = explicit || @environment["TWO_HEAD_WU_PROJECT_ROOT"]
      return Pathname.new(value).expand_path.cleanpath if value && !value.empty?

      candidate = @package_root.join("../..").expand_path.cleanpath
      return candidate if candidate.join("registries/projects_registry.yaml").file?

      raise Error, "project root is required outside the source tree"
    end

    def runtime_config_root
      @data_root.join("config")
    end

    def integration_state_file
      runtime_config_root.join("codex-integration.json")
    end

    def project_map_file
      runtime_config_root.join("local-project-map.json")
    end

    def coverage_gap_file
      local_state_root.join("coverage-gaps.jsonl")
    end

    def proxy_stderr_file
      home = @environment["HOME"].to_s
      home = Dir.home if home.empty?
      Pathname.new(home).join("Library/Logs/TwoHeadWu/agent-observability.log")
    end

    def provider_bootstrap_log
      local_state_root.join("provider-bootstrap.log")
    end

    def verification_marker
      local_state_root.join("verified.json")
    end

    def write_verification_marker
      verification = load_integration_state.fetch("verification", {})
      atomic_write(
        verification_marker,
        JSON.generate(
          "schema_version" => 1,
          "state" => "active",
          "activated_at" => verification["activated_at"] || verification["verified_at"],
          "verified_at" => verification["verified_at"]
        ) + "\n",
        mode: 0o600
      )
    end

    def local_state_root
      home = @environment["HOME"].to_s
      home = Dir.home if home.empty?
      Pathname.new(home).join(".local/state/two-head-wu/agent-observability")
    end

    def with_integration_mutation_lock(&block)
      with_local_state_lock("integration.lock", nonblocking: true, &block)
    end

    def with_local_state_lock(filename, nonblocking: false)
      raise Error, "invalid local lock name" unless filename.match?(/\A[a-z0-9-]+\.lock\z/)

      FileUtils.mkdir_p(local_state_root, mode: 0o700)
      lock_path = local_state_root.join(filename)
      raise Error, "local state lock must not be a symlink: #{lock_path}" if lock_path.symlink?

      File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |file|
        FileUtils.chmod(0o600, lock_path)
        operation = File::LOCK_EX
        operation |= File::LOCK_NB if nonblocking
        unless file.flock(operation)
          raise Error, "another agent-observability integration mutation is in progress"
        end

        yield
      ensure
        file.flock(File::LOCK_UN) rescue nil
      end
    end

    def runtime_package_root
      home = @environment["HOME"].to_s
      home = Dir.home if home.empty?
      Pathname.new(home).join(".local/share/two-head-wu/agent-observability", CAPABILITY_VERSION)
    end

    def install_runtime_bundle!
      runtime_root = runtime_package_root
      if runtime_root.exist? || runtime_root.symlink?
        raise Error, "runtime bundle path must be a regular directory" unless
          runtime_root.directory? && !runtime_root.symlink?
        verify_runtime_bundle!
      else
        FileUtils.mkdir_p(runtime_root.parent, mode: 0o700)
        stage = runtime_root.parent.join(
          ".#{runtime_root.basename}.#{Process.pid}.#{SecureRandom.hex(6)}.stage"
        )
        FileUtils.mkdir_p(stage, mode: 0o700)
        RUNTIME_BUNDLE_FILES.each do |relative|
          source = @package_root.join(relative)
          raise Error, "runtime bundle source is missing: #{relative}" unless source.file? && !source.symlink?

          target = stage.join(relative)
          FileUtils.mkdir_p(target.dirname, mode: 0o700)
          FileUtils.cp(source, target, preserve: true)
        end
        RUNTIME_EXECUTABLES.each { |relative| FileUtils.chmod(0o755, stage.join(relative)) }
        File.rename(stage, runtime_root)
      end
      verify_runtime_bundle!
      write_prelaunch_contract!
    ensure
      FileUtils.rm_rf(stage) if defined?(stage) && stage&.exist?
    end

    def verify_runtime_bundle!
      expected_files = RUNTIME_BUNDLE_FILES.sort
      expected_directories = expected_files.flat_map do |relative|
        parts = relative.split("/")
        (1...parts.length).map { |length| parts.take(length).join("/") }
      end.uniq.sort
      actual_files = []
      actual_directories = []
      Dir.glob(runtime_package_root.join("**/*").to_s, File::FNM_DOTMATCH).each do |path|
        candidate = Pathname.new(path)
        next if %w[. ..].include?(candidate.basename.to_s)

        relative = candidate.relative_path_from(runtime_package_root).to_s
        raise Error, "runtime bundle contains a symlink: #{relative}" if candidate.symlink?
        if candidate.directory?
          actual_directories << relative
        elsif candidate.file?
          actual_files << relative
        else
          raise Error, "runtime bundle contains an unsupported entry: #{relative}"
        end
      end
      unless actual_files.sort == expected_files && actual_directories.sort == expected_directories
        raise Error, "runtime bundle file set drift"
      end

      RUNTIME_BUNDLE_FILES.each do |relative|
        source = @package_root.join(relative)
        raise Error, "runtime bundle source is missing: #{relative}" unless source.file? && !source.symlink?
        target = runtime_package_root.join(relative)
        raise Error, "runtime bundle content drift: #{relative}" unless
          target.file? && !target.symlink? && Digest::SHA256.file(target) == Digest::SHA256.file(source)
        unless target.executable? == source.executable?
          raise Error, "runtime bundle permission drift: #{relative}"
        end
      end
      RUNTIME_EXECUTABLES.each do |relative|
        raise Error, "runtime bundle entrypoint is not executable: #{relative}" unless
          runtime_package_root.join(relative).executable?
      end
      true
    end

    def runtime_bundle_digest(root)
      root = Pathname.new(root).expand_path.cleanpath
      digest = Digest::SHA256.new
      RUNTIME_BUNDLE_FILES.sort.each do |relative|
        entry = root.join(relative)
        unless entry.file? && !entry.symlink?
          raise Error, "provider package entry is missing or unsafe: #{relative}"
        end

        digest << relative << "\0" << (entry.executable? ? "x" : "-") << "\0"
        File.open(entry, "rb") { |file| digest << file.read(65_536) until file.eof? }
        digest << "\0"
      end
      "sha256:#{digest.hexdigest}"
    end

    def runtime_bundle_current?
      verify_runtime_bundle!
    rescue Error, SystemCallError, IOError, ArgumentError
      false
    end

    def write_prelaunch_contract!
      package_digest = runtime_bundle_digest(@package_root)
      atomic_write(
        local_state_root.join("prelaunch.json"),
        JSON.generate(
          "schema_version" => 1,
          "project_root" => @project_root.to_s,
          "data_root" => @data_root.to_s,
          "package_root" => @package_root.to_s,
          "package_digest" => package_digest
        ) + "\n",
        mode: 0o600
      )
      trigger_log = local_state_root.join("provider-trigger.log")
      File.open(trigger_log, File::WRONLY | File::APPEND | File::CREAT, 0o600) { |_file| nil }
      FileUtils.chmod(0o600, trigger_log)
    end

    def launch_agent_file
      home = @environment["HOME"].to_s
      home = Dir.home if home.empty?
      Pathname.new(home).join("Library/LaunchAgents/#{LAUNCH_AGENT_LABEL}.plist")
    end

    def load_integration_state
      return { "schema_version" => 1, "homes" => {} } unless integration_state_file.file?

      ensure_private_file!(integration_state_file)
      value = JSON.parse(integration_state_file.read)
      raise Error, "Codex integration state is invalid" unless value.is_a?(Hash) && value["homes"].is_a?(Hash)

      value
    rescue JSON::ParserError
      raise Error, "Codex integration state is invalid"
    end

    def registered_identity_homes
      identity_status.fetch("identities", []).each_with_object([]) do |identity, output|
        next unless identity["configured"] == true

        output << identity_home(identity.fetch("id"))
      end.uniq.sort
    end

    def home_state_key(home)
      Digest::SHA256.hexdigest(Pathname.new(home).join("config.toml").to_s)[0, 24]
    end

    def installation_snapshots(homes, state)
      paths = homes.map { |home| Pathname.new(home).join("config.toml") }
      paths.concat(state.fetch("homes", {}).values.map { |entry| Pathname.new(entry.fetch("config_path")) })
      paths.concat([
        integration_state_file,
        codex_wrapper_file,
        vscode_settings_file,
        launch_agent_file,
        verification_marker,
        local_state_root.join("prelaunch.json")
      ])
      paths.uniq.map { |path| file_snapshot(path) }
    end

    def file_snapshot(path)
      path = Pathname.new(path)
      raise Error, "refusing to replace a symlinked managed file: #{path}" if path.symlink?

      if path.file?
        { "path" => path.to_s, "present" => true, "content" => path.binread,
          "mode" => path.stat.mode & 0o777 }
      else
        { "path" => path.to_s, "present" => false }
      end
    end

    def restore_file_snapshot(snapshot)
      path = Pathname.new(snapshot.fetch("path"))
      if snapshot.fetch("present")
        atomic_write(path, snapshot.fetch("content"), mode: snapshot.fetch("mode"))
      else
        FileUtils.rm_f(path)
      end
    end

    def rollback_installation(snapshots, launch_agent_was_loaded:)
      errors = []
      bootout_launch_agent!
      snapshots.reverse_each do |snapshot|
        restore_file_snapshot(snapshot)
      rescue StandardError => error
        errors << "restore #{Pathname.new(snapshot.fetch('path')).basename}: #{error.class}"
      end
      if launch_agent_was_loaded && launch_agent_file.file?
        bootstrap_launch_agent!
      end
      errors
    rescue StandardError => error
      errors << "launchd restore: #{error.class}"
      errors
    end

    def install_codex_home!(home, state)
      config = Pathname.new(home).join("config.toml")
      raise Error, "refusing to replace a symlinked Codex config: #{config}" if config.symlink?

      FileUtils.mkdir_p(config.dirname, mode: 0o700)
      content = config.file? ? config.read : ""
      key = home_state_key(home)
      prior_entry = state.fetch("homes", {})[key]
      without_block = remove_managed_otel_block(content)
      without_notify, current_notify = remove_top_level_notify(without_block)
      previous_notify = if managed_notify_command?(current_notify, key)
                          prior_entry && prior_entry["previous_notify"]
                        elsif current_notify.nil? && prior_entry
                          prior_entry["previous_notify"]
                        else
                          current_notify
                        end
      unless previous_notify.nil? || (previous_notify.is_a?(Array) && previous_notify.all? { |item| item.is_a?(String) })
        raise Error, "unsupported top-level notify setting in #{config}"
      end

      entry = {
        "state_key" => key,
        "config_path" => config.to_s,
        "previous_notify" => previous_notify
      }
      state["homes"][key] = entry
      atomic_write(integration_state_file, JSON.pretty_generate(state) + "\n", mode: 0o600)

      rendered = "notify = #{JSON.generate(managed_notify_command(key))}\n"
      rendered += without_notify.sub(/\A\s+/, "")
      rendered += "\n" unless rendered.end_with?("\n")
      rendered += managed_otel_block
      atomic_write(config, rendered, mode: 0o600)
    end

    def restore_plan(entry, allow_previous_managed_version: false)
      config = Pathname.new(entry.fetch("config_path"))
      raise Error, "cannot restore missing Codex config: #{config}" unless config.file?
      raise Error, "refusing to restore a symlinked Codex config: #{config}" if config.symlink?

      original = config.read
      unless original.scan(CONFIG_MARKER_BEGIN).length == 1 && original.scan(CONFIG_MARKER_END).length == 1
        raise Error, "managed OTel block drift prevents safe restore: #{config}"
      end

      content = remove_managed_otel_block(original)
      content, current_notify = remove_top_level_notify(content)
      state_key = entry.fetch("state_key")
      notify_matches = if allow_previous_managed_version
                         managed_notify_command?(current_notify, state_key)
                       else
                         current_notify == managed_notify_command(state_key)
                       end
      unless notify_matches
        raise Error, "managed notify drift prevents safe restore: #{config}"
      end

      previous = entry["previous_notify"]
      restored = previous ? "notify = #{JSON.generate(previous)}\n" : ""
      restored += content.sub(/\A\s+/, "")
      { "path" => config, "original" => original, "restored" => restored, "mode" => 0o600 }
    end

    def install_launch_surfaces!(state)
      existing = state["launch_surfaces"]
      if existing
        current_plans = launch_surface_restore_plans(state)
        wrapper_state = existing.fetch("codex_wrapper")
        settings_state = existing.fetch("vscode_settings")
        wrapper = Pathname.new(wrapper_state.fetch("path"))
        wrapper_original = wrapper_state.fetch("previous_content")
        wrapper_current = current_plans.fetch(0).fetch("original")
        wrapper_mode = wrapper_state.fetch("mode")
        settings_path = Pathname.new(settings_state.fetch("path"))
        settings_current = current_plans.fetch(1).fetch("original")
        settings_mode = settings_state.fetch("mode")
        previous_present = settings_state.fetch("previous_present")
        previous_value = settings_state["previous_value"]
      else
        wrapper = codex_wrapper_file
        raise Error, "Codex PATH wrapper is missing or not executable: #{wrapper}" unless wrapper.file? && wrapper.executable?
        raise Error, "refusing to replace a symlinked Codex PATH wrapper" if wrapper.symlink?
        wrapper_original = wrapper.read
        wrapper_current = wrapper_original
        wrapper_mode = wrapper.stat.mode & 0o777
        settings_path = vscode_settings_file
        settings_current = settings_path.file? ? settings_path.read : "{}\n"
        settings_mode = settings_path.file? ? settings_path.stat.mode & 0o777 : 0o600
        initial_settings = parse_json_object(settings_current, "VS Code user settings")
        previous_present = initial_settings.key?("chatgpt.cliExecutable")
        previous_value = initial_settings["chatgpt.cliExecutable"]
      end
      raise Error, "refusing to replace a symlinked Codex PATH wrapper" if wrapper.symlink?
      raise Error, "refusing to replace symlinked VS Code user settings" if settings_path.symlink?

      wrapper_managed = managed_wrapper_content(wrapper_original)
      settings = parse_json_object(settings_current, "VS Code user settings")
      target = observed_codex_adapter.to_s
      raise Error, "recursive VS Code Codex wrapper target refused" if Pathname.new(target).expand_path == wrapper.expand_path
      settings["chatgpt.cliExecutable"] = target
      settings_managed = JSON.pretty_generate(settings) + "\n"

      plans = [
        { "path" => wrapper, "original" => wrapper_current, "restored" => wrapper_managed,
          "mode" => wrapper_mode },
        { "path" => settings_path, "original" => settings_current, "restored" => settings_managed,
          "mode" => settings_mode }
      ]
      changed = []
      begin
        plans.each do |plan|
          atomic_write(plan.fetch("path"), plan.fetch("restored"), mode: plan.fetch("mode"))
          changed << plan
        end
      rescue StandardError
        changed.reverse_each do |plan|
          atomic_write(plan.fetch("path"), plan.fetch("original"), mode: plan.fetch("mode"))
        rescue StandardError
          nil
        end
        raise
      end
      state["launch_surfaces"] = {
        "codex_wrapper" => {
          "path" => wrapper.to_s,
          "previous_content" => wrapper_original,
          "managed_digest" => "sha256:#{Digest::SHA256.hexdigest(wrapper_managed)}",
          "mode" => plans.fetch(0).fetch("mode")
        },
        "vscode_settings" => {
          "path" => settings_path.to_s,
          "previous_present" => previous_present,
          "previous_value" => previous_value,
          "managed_value" => target,
          "mode" => plans.fetch(1).fetch("mode")
        }
      }
      true
    end

    def launch_surface_restore_plans(state)
      surfaces = state["launch_surfaces"]
      return [] unless surfaces
      wrapper_state = surfaces.fetch("codex_wrapper")
      wrapper = Pathname.new(wrapper_state.fetch("path"))
      raise Error, "cannot restore missing Codex PATH wrapper: #{wrapper}" unless wrapper.file?
      wrapper_current = wrapper.read
      current_digest = "sha256:#{Digest::SHA256.hexdigest(wrapper_current)}"
      unless current_digest == wrapper_state.fetch("managed_digest") &&
             wrapper_current.scan(WRAPPER_MARKER_BEGIN).length == 1 &&
             wrapper_current.scan(WRAPPER_MARKER_END).length == 1
        raise Error, "managed Codex PATH wrapper drift prevents safe restore: #{wrapper}"
      end

      settings_state = surfaces.fetch("vscode_settings")
      settings_path = Pathname.new(settings_state.fetch("path"))
      raise Error, "cannot restore missing VS Code user settings: #{settings_path}" unless settings_path.file?
      settings_current = settings_path.read
      settings = parse_json_object(settings_current, "VS Code user settings")
      unless settings["chatgpt.cliExecutable"] == settings_state.fetch("managed_value")
        raise Error, "managed VS Code CLI setting drift prevents safe restore: #{settings_path}"
      end
      if settings_state.fetch("previous_present")
        settings["chatgpt.cliExecutable"] = settings_state["previous_value"]
      else
        settings.delete("chatgpt.cliExecutable")
      end

      [
        { "path" => wrapper, "original" => wrapper_current,
          "restored" => wrapper_state.fetch("previous_content"), "mode" => wrapper_state.fetch("mode") },
        { "path" => settings_path, "original" => settings_current,
          "restored" => JSON.pretty_generate(settings) + "\n", "mode" => settings_state.fetch("mode") }
      ]
    rescue KeyError
      raise Error, "launch surface recovery state is invalid"
    end

    def parse_json_object(content, label)
      value = JSON.parse(content)
      raise Error, "#{label} must be a JSON object" unless value.is_a?(Hash)

      value
    rescue JSON::ParserError
      raise Error, "#{label} is not valid JSON"
    end

    def codex_wrapper_file
      Pathname.new(@environment.fetch("HOME", Dir.home)).join(".local/bin/codex")
    end

    def vscode_settings_file
      Pathname.new(@environment.fetch("HOME", Dir.home)).join("Library/Application Support/Code/User/settings.json")
    end

    def observed_codex_adapter
      runtime_package_root.join("adapters/codex-observed")
    end

    def wrapper_hook_block
      <<~SH.chomp
        #{WRAPPER_MARKER_BEGIN}
        _two_head_wu_observability_supervisor="#{observed_codex_adapter}"
        if [[ "${CODEX_BIN:-}" != "$_two_head_wu_observability_supervisor" ]]; then
          export TWO_HEAD_WU_OBSERVABILITY_VENDOR_CODEX="${CODEX_BIN:-}"
          export CODEX_BIN="$_two_head_wu_observability_supervisor"
        fi
        unset _two_head_wu_observability_supervisor
        #{WRAPPER_MARKER_END}
      SH
    end

    def managed_wrapper_content(original)
      raise Error, "Codex PATH wrapper is unexpectedly large" if original.bytesize > 1_048_576
      if original.include?(WRAPPER_MARKER_BEGIN) || original.include?(WRAPPER_MARKER_END)
        raise Error, "untracked observability hook already exists in Codex PATH wrapper"
      end
      insertion = original.index("set -euo pipefail\n")
      raise Error, "Codex PATH wrapper lacks the expected safety preamble" unless insertion

      insertion += "set -euo pipefail\n".bytesize
      original.dup.insert(insertion, "\n#{wrapper_hook_block}\n")
    end

    def remove_managed_otel_block(content)
      pattern = /\n?#{Regexp.escape(CONFIG_MARKER_BEGIN)}\n.*?#{Regexp.escape(CONFIG_MARKER_END)}\n?/m
      stripped = content.gsub(pattern, "\n")
      if stripped.match?(/^\s*\[otel\]\s*(?:#.*)?$/)
        raise Error, "unmanaged [otel] configuration exists; refusing to overwrite it"
      end
      stripped
    end

    def remove_top_level_notify(content)
      lines = content.lines
      table_index = lines.index { |line| line.match?(/^\s*\[/) } || lines.length
      notify_indexes = (0...table_index).select { |index| lines[index].match?(/^\s*notify\s*=/) }
      raise Error, "multiple top-level notify settings are unsupported" if notify_indexes.length > 1
      return [content, nil] if notify_indexes.empty?

      index = notify_indexes.first
      match = lines[index].match(/^\s*notify\s*=\s*(\[.*\])\s*(?:#.*)?$/)
      raise Error, "multiline or non-array top-level notify setting is unsupported" unless match
      notify = JSON.parse(match[1])
      raise Error, "top-level notify must be an array of strings" unless
        notify.is_a?(Array) && notify.all? { |item| item.is_a?(String) }

      lines.delete_at(index)
      [lines.join, notify]
    rescue JSON::ParserError
      raise Error, "top-level notify must use a JSON-compatible TOML string array"
    end

    def managed_notify_command(state_key)
      [
        runtime_package_root.join("adapters/agent-observability").to_s,
        "notify",
        "--project-root", @project_root.to_s,
        "--data-root", @data_root.to_s,
        "--state-key", state_key
      ]
    end

    def managed_notify_command?(command, state_key)
      return false unless command.is_a?(Array) && command.all? { |item| item.is_a?(String) }
      return false unless command.drop(1) == managed_notify_command(state_key).drop(1)

      executable = Pathname.new(command.fetch(0)).expand_path.cleanpath
      managed_root = runtime_package_root.parent
      relative = executable.relative_path_from(managed_root)
      parts = relative.each_filename.to_a
      parts.length == 3 && parts.fetch(0).match?(/\A\d+\.\d+\.\d+\z/) &&
        parts.drop(1) == %w[adapters agent-observability]
    rescue ArgumentError, TypeError, IndexError
      false
    end

    def managed_notify_token(state_key)
      JSON.generate(managed_notify_command(state_key))
    end

    def managed_otel_block
      <<~TOML
        #{CONFIG_MARKER_BEGIN}
        [otel]
        environment = "two-head-wu-local"
        log_user_prompt = false
        exporter = "none"
        metrics_exporter = "none"
        trace_exporter = { otlp-http = { endpoint = "http://127.0.0.1:#{FRONTEND_PORT}/v1/traces", protocol = "binary" } }
        span_attributes = { "project.id" = "local-unclassified", "agent.logical_identity" = "#{LOGICAL_IDENTITY}", "agent.runtime" = "#{RUNTIME_ID}", "runtime.surface" = "#{RUNTIME_SURFACE}", "observability.schema" = "#{SCHEMA_VERSION}" }
        #{CONFIG_MARKER_END}
      TOML
    end

    def install_launch_agent!
      raise Error, "lazy OTLP proxy is available only on macOS" unless RbConfig::CONFIG["host_os"].include?("darwin")

      FileUtils.mkdir_p(launch_agent_file.dirname)
      prepare_proxy_stderr_file!
      atomic_write(launch_agent_file, launch_agent_plist, mode: 0o600)
      bootout_launch_agent!
      20.times do
        break unless launch_agent_loaded?
        sleep 0.1
      end
      bootstrap_launch_agent!
    end

    def bootstrap_launch_agent!
      result = nil
      3.times do
        result = @runner.capture({}, "/bin/launchctl", "bootstrap", launch_domain, launch_agent_file.to_s,
                                 timeout_seconds: 30)
        break if result.success?
        sleep 0.5
      end
      raise Error, result.stderr.to_s.strip.empty? ? "failed to register lazy OTLP LaunchAgent" : result.stderr.to_s.strip unless result.success?
    end

    def bootout_launch_agent!
      return Result.new(stdout: "", stderr: "", status: 0) unless RbConfig::CONFIG["host_os"].include?("darwin")

      @runner.capture({}, "/bin/launchctl", "bootout", "#{launch_domain}/#{LAUNCH_AGENT_LABEL}",
                      timeout_seconds: 30)
    end

    def unload_launch_agent!
      result = bootout_launch_agent!
      if !result.success? && launch_agent_loaded?
        message = result.stderr.to_s.strip
        raise Error, message.empty? ? "failed to unload lazy OTLP LaunchAgent" : message
      end
      20.times do
        break unless launch_agent_loaded?
        sleep 0.1
      end
      raise Error, "lazy OTLP LaunchAgent remains loaded" if launch_agent_loaded?

      true
    end

    def stop_proxy_process!
      return unless launch_agent_loaded?

      @runner.capture({}, "/bin/launchctl", "kill", "SIGTERM", "#{launch_domain}/#{LAUNCH_AGENT_LABEL}",
                      timeout_seconds: 10)
    end

    def launch_agent_loaded?
      return false unless RbConfig::CONFIG["host_os"].include?("darwin")

      @runner.capture({}, "/bin/launchctl", "print", "#{launch_domain}/#{LAUNCH_AGENT_LABEL}",
                      timeout_seconds: 5).success?
    end

    def launch_agent_current?
      launch_agent_file.file? && !launch_agent_file.symlink? && launch_agent_file.read == launch_agent_plist
    rescue Errno::EACCES, Errno::ENOENT
      false
    end

    def launch_domain
      "gui/#{Process.uid}"
    end

    def prepare_proxy_stderr_file!
      FileUtils.mkdir_p(proxy_stderr_file.dirname, mode: 0o700)
      if proxy_stderr_file.file? && proxy_stderr_file.size > 1_048_576
        suffix = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
        archive = Pathname.new("#{proxy_stderr_file}.#{suffix}.archive")
        counter = 1
        while archive.exist?
          archive = Pathname.new("#{proxy_stderr_file}.#{suffix}.#{counter}.archive")
          counter += 1
        end
        FileUtils.mv(proxy_stderr_file, archive)
        FileUtils.chmod(0o600, archive)
      end
      File.open(proxy_stderr_file, File::WRONLY | File::APPEND | File::CREAT, 0o600) { |_file| nil }
      FileUtils.chmod(0o600, proxy_stderr_file)
    end

    def launch_agent_plist
      proxy = runtime_package_root.join("integrations/lazy-otlp-proxy")
      arguments = [
        "/usr/bin/ruby", proxy.to_s,
        "--project-root", @project_root.to_s,
        "--data-root", @data_root.to_s
      ].map { |value| "      <string>#{CGI.escapeHTML(value)}</string>" }.join("\n")
      <<~PLIST
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          <string>#{LAUNCH_AGENT_LABEL}</string>
          <key>ProgramArguments</key>
          <array>
        #{arguments}
          </array>
          <key>EnvironmentVariables</key>
          <dict>
            <key>PATH</key>
            <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
          </dict>
          <key>RunAtLoad</key>
          <false/>
          <key>KeepAlive</key>
          <false/>
          <key>ProcessType</key>
          <string>Background</string>
          <key>ThrottleInterval</key>
          <integer>10</integer>
          <key>Sockets</key>
          <dict>
            <key>Listener</key>
            <dict>
              <key>SockNodeName</key>
              <string>127.0.0.1</string>
              <key>SockServiceName</key>
              <string>#{FRONTEND_PORT}</string>
              <key>SockType</key>
              <string>stream</string>
            </dict>
          </dict>
          <key>StandardOutPath</key>
          <string>/dev/null</string>
          <key>StandardErrorPath</key>
          <string>#{CGI.escapeHTML(proxy_stderr_file.to_s)}</string>
        </dict>
        </plist>
      PLIST
    end

    def notify_value(payload, *keys)
      keys.each do |key|
        value = payload[key]
        return value unless value.nil?
      end
      nil
    end

    def notify_project(payload)
      cwd = notify_value(payload, "cwd", "working-directory", "working_directory").to_s
      unless !cwd.empty? && Pathname.new(cwd).absolute?
        record_coverage_gap("notify-missing-project")
        return {
          "id" => "local-unclassified", "kind" => "unclassified", "display_name" => "未归类的本地项目",
          "attribution" => "notify-cwd-unavailable"
        }
      end

      resolve_local_project(cwd).merge("attribution" => "notify-cwd")
    rescue ArgumentError
      record_coverage_gap("notify-missing-project")
      {
        "id" => "local-unclassified", "kind" => "unclassified", "display_name" => "未归类的本地项目",
        "attribution" => "notify-cwd-unavailable"
      }
    end

    def request_provider_start
      return false if otlp_backend_ready?
      return true if signal_provider_trigger

      FileUtils.mkdir_p(provider_bootstrap_log.dirname, mode: 0o700)
      command = [
        runtime_package_root.join("integrations/provider-bootstrap").to_s,
        "--project-root", @project_root.to_s,
        "--data-root", @data_root.to_s,
        "--package-root", provider_bootstrap_package_root.to_s
      ]
      pid = File.open(provider_bootstrap_log, File::WRONLY | File::APPEND | File::CREAT, 0o600) do |log|
        FileUtils.chmod(0o600, provider_bootstrap_log)
        Process.spawn(*command, out: log, err: log)
      end
      Process.detach(pid)
      true
    rescue Error, SystemCallError
      record_coverage_gap("provider-start-failed")
      false
    end

    def provider_bootstrap_package_root
      contract_path = local_state_root.join("prelaunch.json")
      unless contract_path.file?
        if @package_root == runtime_package_root
          raise Error, "runtime notify has no installed provider package contract"
        end
        return @package_root
      end

      ensure_private_file!(contract_path)
      contract = JSON.parse(contract_path.read)
      raise Error, "prelaunch provider package contract is invalid" unless contract.is_a?(Hash)

      expected_digest = contract.fetch("package_digest").to_s
      unless expected_digest.match?(/\Asha256:[0-9a-f]{64}\z/)
        raise Error, "prelaunch provider package digest is invalid"
      end
      candidate = Pathname.new(contract.fetch("package_root").to_s).expand_path.cleanpath
      unless candidate.absolute? && candidate.directory? && !candidate.symlink?
        raise Error, "prelaunch provider package root is unavailable"
      end
      candidate = candidate.realpath.cleanpath
      project_real = @project_root.realpath.cleanpath
      unless candidate.to_s.start_with?("#{project_real}/")
        raise Error, "prelaunch provider package root is outside the registered project"
      end
      manifest = YAML.safe_load(candidate.join("capability.yaml").read, aliases: false)
      unless manifest.is_a?(Hash) && manifest["id"] == "agent-observability" &&
             manifest["version"] == CAPABILITY_VERSION
        raise Error, "prelaunch provider package contract does not match #{CAPABILITY_VERSION}"
      end
      unless runtime_bundle_digest(candidate) == expected_digest
        raise Error, "prelaunch provider package content has drifted"
      end

      candidate
    rescue JSON::ParserError, Psych::Exception, KeyError, Errno::EACCES, Errno::ENOENT
      raise Error, "prelaunch provider package contract is invalid"
    end

    def signal_provider_trigger
      socket_path = local_state_root.join("provider-trigger.sock")
      return false unless socket_path.socket?

      socket = UNIXSocket.new(socket_path.to_s)
      socket.write("start\n")
      socket.close
      true
    rescue SystemCallError, IOError
      false
    end

    def resolve_local_project(raw_path)
      path = Pathname.new(raw_path.to_s).expand_path.cleanpath
      path = path.realpath if path.exist?
      raise Error, "notify working directory must be absolute" unless path.absolute?

      registered = registered_projects.select do |item|
        root = item.fetch("path")
        path.to_s == root || path.to_s.start_with?("#{root}/")
      end.max_by { |item| item.fetch("path").length }
      if registered
        return { "id" => registered.fetch("id"), "kind" => "registered", "display_name" => registered.fetch("name") }
      end

      git_root = resolve_git_root(path)
      canonical = (git_root || path).to_s
      kind = git_root ? "git" : "directory"
      project_id = "local-#{kind == 'git' ? 'git' : 'dir'}-#{Digest::SHA256.hexdigest(canonical)[0, 16]}"
      display_name = Pathname.new(canonical).basename.to_s
      persist_local_project(canonical, project_id, kind, display_name)
      { "id" => project_id, "kind" => kind, "display_name" => display_name }
    rescue Errno::EACCES, Errno::ENOENT
      project_id = "local-dir-#{Digest::SHA256.hexdigest(raw_path.to_s)[0, 16]}"
      { "id" => project_id, "kind" => "directory", "display_name" => "local directory" }
    end

    def registered_projects
      registry = YAML.safe_load(@project_root.join("registries/projects_registry.yaml").read)
      return [] unless registry.is_a?(Hash)

      Array(registry["projects"]).each_with_object([]) do |item, output|
        next unless item.is_a?(Hash)

        raw_path = item["path"].to_s
        next unless safe_project_id(item["id"]) && Pathname.new(raw_path).absolute?

        canonical = begin
          candidate = Pathname.new(raw_path).expand_path.cleanpath
          candidate.exist? ? candidate.realpath.to_s : candidate.to_s
        rescue Errno::EACCES, Errno::ENOENT
          raw_path
        end
        output << { "id" => item.fetch("id"), "name" => item.fetch("name", item.fetch("id")), "path" => canonical }
      end
    rescue Psych::Exception, Errno::ENOENT
      []
    end

    def registered_capability_ids
      registry = YAML.safe_load(@project_root.join("catalog/packages_registry.yaml").read)
      return [] unless registry.is_a?(Hash)

      Array(registry["packages"]).each_with_object([]) do |item, output|
        next unless item.is_a?(Hash)

        capability_id = item["id"]
        output << capability_id if safe_project_id(capability_id)
      end
    rescue Psych::Exception, Errno::ENOENT
      []
    end

    def resolve_git_root(path)
      result = @runner.capture({}, "git", "-C", path.to_s, "rev-parse", "--show-toplevel",
                               timeout_seconds: 3)
      return nil unless result.success?

      value = result.stdout.to_s.strip
      return nil unless Pathname.new(value).absolute?

      candidate = Pathname.new(value).expand_path.cleanpath
      candidate.exist? ? candidate.realpath : candidate
    rescue Errno::EACCES, Errno::ENOENT
      nil
    end

    def persist_local_project(path, project_id, kind, display_name)
      with_local_state_lock("project-map.lock") do
        map = load_project_map
        map["projects"][project_id] = {
          "path" => path,
          "kind" => kind,
          "display_name" => display_name,
          "last_seen_at" => Time.now.utc.iso8601
        }
        atomic_write(project_map_file, JSON.pretty_generate(map) + "\n", mode: 0o600)
      end
    end

    def load_project_map
      return { "schema_version" => 1, "projects" => {} } unless project_map_file.file?

      ensure_private_file!(project_map_file)
      value = JSON.parse(project_map_file.read)
      raise Error, "private project map is invalid" unless value.is_a?(Hash) && value["projects"].is_a?(Hash)
      value
    rescue JSON::ParserError
      raise Error, "private project map is invalid"
    end

    def project_labels
      labels = registered_projects.each_with_object({}) do |project, output|
        output[project.fetch("id")] = project.fetch("name")
      end
      load_project_map.fetch("projects", {}).each do |project_id, item|
        labels[project_id] = item.fetch("display_name", project_id)
      end
      labels["local-unclassified"] = "未归类的本地项目"
      labels
    end

    def safe_project_id(value)
      value.is_a?(String) && value.match?(/\A[a-z0-9][a-z0-9._-]{0,79}\z/)
    end

    def send_project_mapping(conversation_id, project, phase: nil)
      payload = project_mapping_payload(conversation_id, project)
      request = Net::HTTP::Post.new("/v1/traces")
      request["Content-Type"] = "application/json"
      request["X-Two-Head-Wu-Observability-Phase"] = phase if phase
      request.body = JSON.generate(payload)
      http = Net::HTTP.new("127.0.0.1", FRONTEND_PORT)
      http.open_timeout = 2
      http.read_timeout = 2
      response = http.start { |connection| connection.request(request) }
      return true if response.code.to_i.between?(200, 299)

      record_coverage_gap("frontend-unavailable", project_id: project.fetch("id"))
      false
    rescue SystemCallError, IOError, Timeout::Error, Net::HTTPBadResponse
      record_coverage_gap("frontend-unavailable", project_id: project.fetch("id"))
      false
    end

    def project_mapping_payload(conversation_id, project)
      now = (Time.now.to_r * 1_000_000_000).to_i.to_s
      attributes = {
        "project.id" => project.fetch("id"),
        "project.kind" => project.fetch("kind"),
        "project.attribution" => project.fetch("attribution", "notify-cwd"),
        "agent.logical_identity" => LOGICAL_IDENTITY,
        "agent.runtime" => RUNTIME_ID,
        "runtime.surface" => RUNTIME_SURFACE,
        "observability.schema" => SCHEMA_VERSION.to_s,
        "conversation.id" => conversation_id,
        "event.name" => "two_head_wu.session_project"
      }.map do |key, value|
        { "key" => key, "value" => { "stringValue" => value.to_s } }
      end
      payload = {
        "resourceSpans" => [{
          "resource" => { "attributes" => [{
            "key" => "service.name", "value" => { "stringValue" => "two-head-wu-agent-observability" }
          }] },
          "scopeSpans" => [{
            "scope" => { "name" => "two-head-wu-agent-observability", "version" => CAPABILITY_VERSION },
            "spans" => [{
              # The collector's OTLP/HTTP JSON decoder expects canonical hex
              # identifiers (32/16 characters), matching the OpenTelemetry JSON
              # encoding accepted by the pinned collector build.
              "traceId" => SecureRandom.hex(16),
              "spanId" => SecureRandom.hex(8),
              "name" => "two_head_wu.session_project",
              "kind" => 1,
              "startTimeUnixNano" => now,
              "endTimeUnixNano" => now,
              "attributes" => attributes,
              "status" => { "code" => 1 }
            }]
          }]
        }]
      }
      payload
    end

    def forward_previous_notify(state_key, payload_text)
      entry = load_integration_state.fetch("homes", {})[state_key]
      command = entry && entry["previous_notify"]
      return false unless command.is_a?(Array) && command.all? { |item| item.is_a?(String) } && !command.empty?

      pid = Process.spawn(*command, payload_text, out: File::NULL, err: File::NULL)
      Process.detach(pid)
      true
    rescue StandardError
      false
    end

    def all_coverage_gaps
      return [] unless coverage_gap_file.file?

      activated_at = verification_activated_at
      coverage_gap_file.each_line.each_with_object([]) do |line, output|
        begin
          row = JSON.parse(line)
          next unless row.is_a?(Hash)

          row["phase"] ||= "commissioning"
          timestamp = Time.parse(row.fetch("timestamp"))
          if activated_at && timestamp < activated_at && row["phase"] != "commissioning"
            row["recorded_phase"] = row["phase"]
            row["phase"] = "commissioning"
            row["classification"] = "pre-verification-activation"
          end
          output << row
        rescue JSON::ParserError, KeyError, ArgumentError, TypeError
          nil
        end
      end
    end

    def verification_activated_at
      verification = load_integration_state.fetch("verification", {})
      history = verification_history
      value = verification["activated_at"] || verification["verified_at"] ||
              history["activated_at"] || history["verified_at"]
      value ? Time.parse(value) : nil
    rescue ArgumentError
      nil
    end

    def verification_history
      return {} unless verification_marker.file?

      value = JSON.parse(verification_marker.read)
      value.is_a?(Hash) ? value : {}
    rescue JSON::ParserError, Errno::EACCES, Errno::ENOENT
      {}
    end

    def recent_coverage_gaps(hours: 24, limit: 100, phase: nil)
      cutoff = Time.now.utc - (hours * 3600)
      matching = all_coverage_gaps.each_with_object([]) do |row, output|
        begin
          next if phase && row["phase"] != phase
          output << row if Time.parse(row.fetch("timestamp")) >= cutoff
        rescue KeyError, ArgumentError
          nil
        end
      end
      matching.last(limit)
    end

    def integration_verified?
      launch_agent_current? && verification_history["state"] == "active"
    end

    def environment_file
      runtime_config_root.join("provider.env")
    end

    def runtime_manifest
      runtime_config_root.join("runtime.json")
    end

    def clickhouse_data_root
      @data_root.join("clickhouse")
    end

    def openlit_data_root
      @data_root.join("openlit")
    end

    def colima_cache_home
      @colima_home.join("_cache")
    end

    def default_colima_home
      parts = @project_root.each_filename.to_a
      if @project_root.to_s.start_with?("/Volumes/") && parts[1]
        # Lima's Unix-domain socket path is capped at 104 bytes on macOS. The
        # canonical project path contains non-ASCII bytes and cannot safely host it.
        return Pathname.new("/Volumes").join(parts[1], ".ltw-ao").expand_path.cleanpath
      end

      @project_root.join("var/large-assets/environments/agent-observability/colima").expand_path.cleanpath
    end

    def default_data_root
      return @colima_home.join("data/agent-observability") if @project_root.to_s.start_with?("/Volumes/")

      @project_root.join("var/large-assets/agent-observability")
    end

    def deploy_root
      @package_root.join("deploy")
    end

    def compose_file
      deploy_root.join("docker-compose.yaml")
    end

    def configured?
      environment_file.file? && runtime_manifest.file?
    end

    def require_configured!
      raise Error, "agent-observability is not configured; run configure first" unless configured?
      ensure_private_file!(environment_file)
      ensure_private_file!(runtime_manifest)
      expected = runtime_contract
      actual = JSON.parse(runtime_manifest.read)
      raise Error, "runtime manifest is invalid" unless actual.is_a?(Hash)

      expected.each do |key, value|
        raise Error, "runtime contract drift for #{key}" unless actual[key] == value
      end
    rescue JSON::ParserError
      raise Error, "runtime manifest is invalid"
    end

    def unconfigured_status
      {
        "result" => "status",
        "configured" => false,
        "healthy" => false,
        "provider_healthy" => false,
        "database_healthy" => false,
        "privacy_healthy" => false,
        "project" => PROJECT_ID,
        "logical_identity" => LOGICAL_IDENTITY,
        "collection_mode" => "owner-local-all-codex",
        "trace_only" => true,
        "persistent_codex_config_changed" => integration_state_file.file?,
        "external_volume" => external_volume?,
        "data_root" => @data_root.to_s
      }
    end

    def verify_external_project_root!
      return if test_external_override?
      raise Error, "project root must be beneath /Volumes on external storage" unless external_volume?
      return unless RbConfig::CONFIG["host_os"].include?("darwin")

      filesystem = @runner.capture(
        {}, "df", "-P", @project_root.to_s, timeout_seconds: COMMAND_TIMEOUT_SECONDS
      )
      device = filesystem.stdout.lines.last.to_s.split.first
      raise Error, "cannot resolve external volume device" unless filesystem.success? && device&.start_with?("/dev/")

      result = @runner.capture({}, "diskutil", "info", device, timeout_seconds: COMMAND_TIMEOUT_SECONDS)
      raise Error, "cannot verify external APFS storage" unless result.success?
      unless result.stdout.match?(/File System Personality:\s+APFS/i) ||
             result.stdout.match?(/Type \(Bundle\):\s+apfs/i)
        raise Error, "project volume must use APFS"
      end
    end

    def external_volume?
      @project_root.to_s.start_with?("/Volumes/") && @data_root.to_s.start_with?("/Volumes/")
    end

    def test_external_override?
      @environment["TWO_HEAD_WU_OBSERVABILITY_ALLOW_NON_EXTERNAL_FOR_TEST"] == "1"
    end

    def verify_confined_data_root!
      allowed = [
        @project_root.join("var/large-assets").expand_path.cleanpath,
        @colima_home.join("data").expand_path.cleanpath
      ]
      return if allowed.any? do |root|
        @data_root.to_s == root.to_s || @data_root.to_s.start_with?("#{root}/")
      end

      raise Error, "data root must remain beneath a registered observability storage root"
    end

    def verify_no_symlink_ancestors!(path)
      cursor = path
      existing = []
      until cursor.exist? || cursor.root?
        existing << cursor
        cursor = cursor.parent
      end
      raise Error, "runtime path ancestor is a symlink: #{cursor}" if cursor.symlink?
      existing.reverse_each do |item|
        raise Error, "runtime path component is a symlink: #{item}" if item.symlink?
      end
    end

    def ensure_private_file!(path)
      raise Error, "private environment file is missing" unless path.file?
      raise Error, "private environment file must not be a symlink" if path.symlink?
      mode = path.stat.mode & 0o777
      raise Error, "private environment file permissions must be 0600" unless mode == 0o600
    end

    def ensure_environment_file!
      created = !environment_file.file?
      values = if created
                 {
                   "OPENLIT_DB_NAME" => "openlit",
                   "OPENLIT_DB_USER" => "openlit",
                   "OPENLIT_DB_PASSWORD" => SecureRandom.hex(32)
                 }
               else
                 ensure_private_file!(environment_file)
                 existing = provider_environment
                 %w[OPENLIT_DB_NAME OPENLIT_DB_USER OPENLIT_DB_PASSWORD].each do |key|
                   raise Error, "private environment file is missing #{key}" if existing[key].to_s.empty?
                 end
                 existing
               end
      atomic_write(
        environment_file,
        [
          "OPENLIT_DB_NAME=#{values.fetch('OPENLIT_DB_NAME')}",
          "OPENLIT_DB_USER=#{values.fetch('OPENLIT_DB_USER')}",
          "OPENLIT_DB_PASSWORD=#{values.fetch('OPENLIT_DB_PASSWORD')}",
          "TWO_HEAD_WU_OBSERVABILITY_DATA_ROOT=#{@data_root}",
          ""
        ].join("\n"),
        mode: 0o600
      )
      created
    end

    def atomic_write(path, content, mode:)
      FileUtils.mkdir_p(path.dirname, mode: 0o700)
      temporary = path.dirname.join(
        ".#{path.basename}.#{Process.pid}.#{SecureRandom.hex(6)}.tmp"
      )
      File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, mode) do |file|
        file.write(content)
        file.flush
        file.fsync
      end
      File.rename(temporary, path)
      FileUtils.chmod(mode, path)
    ensure
      FileUtils.rm_f(temporary) if defined?(temporary) && temporary.exist?
    end

    def require_commands!
      missing = REQUIRED_COMMANDS.reject { |command| command_available?(command) }
      raise Error, "missing required commands: #{missing.join(', ')}" unless missing.empty?
    end

    def command_available?(command)
      !command_path(command).nil?
    end

    def command_path(command)
      @environment.fetch("PATH", ENV.fetch("PATH", "")).split(File::PATH_SEPARATOR).each do |directory|
        candidate = Pathname.new(directory).join(command)
        return candidate.to_s if candidate.file? && candidate.executable?
      end
      nil
    end

    def colima_environment
      {
        "COLIMA_HOME" => @colima_home.to_s,
        "COLIMA_CACHE_HOME" => colima_cache_home.to_s
      }
    end

    def compose_environment
      colima_environment.merge(
        "DOCKER_HOST" => "unix://#{docker_socket_path}",
        "TWO_HEAD_WU_OBSERVABILITY_DATA_ROOT" => @data_root.to_s
      )
    end

    def docker_socket_path
      @colima_home.join(PROFILE, "docker.sock")
    end

    def run_colima!(*arguments, timeout_seconds:, allow_failure: false)
      run!([command_path("colima") || "colima", *arguments],
           environment: colima_environment, timeout_seconds: timeout_seconds, allow_failure: allow_failure)
    end

    def colima_running?
      return false unless command_available?("colima")

      result = @runner.capture(
        colima_environment, command_path("colima"), "status", PROFILE, "--json",
        timeout_seconds: COMMAND_TIMEOUT_SECONDS
      )
      return false unless result.success?

      data = JSON.parse(result.stdout)
      return false unless data.is_a?(Hash)

      data["status"] == "Running" || data["status"] == "running" ||
        (data["runtime"] == "docker" && !data["docker_socket"].to_s.empty?)
    rescue JSON::ParserError
      false
    end

    def start_colima!
      return if colima_running?

      volume_name = @project_root.each_filename.to_a[1]
      raise Error, "cannot determine external volume mount" if volume_name.to_s.empty?
      volume_root = Pathname.new("/Volumes").join(volume_name)
      run_colima!(
        "start", PROFILE,
        "--runtime", "docker",
        "--arch", "aarch64",
        "--vm-type", "vz",
        "--mount-type", "virtiofs",
        "--mount", "#{volume_root}:w",
        "--cpus", COLIMA_CPUS.to_s,
        "--memory", COLIMA_MEMORY_GIB.to_s,
        "--disk", COLIMA_DISK_GIB.to_s,
        "--activate=false",
        "--ssh-config=false",
        timeout_seconds: 600
      )
      raise Error, "dedicated Colima profile did not reach running state" unless colima_running?
    end

    def wait_for_docker!(seconds)
      docker = command_path("docker")
      raise Error, "docker is unavailable" unless docker

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      loop do
        result = @runner.capture(
          compose_environment, docker, "info",
          timeout_seconds: 5
        )
        return true if result.success?
        raise Error, "dedicated Docker context did not become ready within #{seconds} seconds" if
          Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep 1
      end
    end

    def compose_command
      docker = command_path("docker")
      if docker
        result = @runner.capture(
          compose_environment, docker, "compose", "version",
          timeout_seconds: COMMAND_TIMEOUT_SECONDS
        )
        return [docker, "compose"] if result.success?
      end

      standalone = command_path("docker-compose")
      return [standalone] if standalone

      nil
    end

    def require_compose!
      raise Error, "Docker Compose v2 is unavailable" unless compose_command
    end

    def compose!(*arguments, timeout_seconds:, allow_failure: false)
      base = compose_command
      raise Error, "Docker Compose v2 is unavailable" unless base
      command = [*base, "--env-file", environment_file.to_s, "-f", compose_file.to_s, *arguments]
      run!(command, environment: compose_environment, timeout_seconds: timeout_seconds, allow_failure: allow_failure)
    end

    def validate_provider_configuration!
      compose!("config", "--quiet", timeout_seconds: 60)
      docker = command_path("docker")
      command = [
        docker, "run", "--rm",
        "-v", "#{deploy_root.join('otel-collector-config.yaml')}:/etc/otel/config.yaml:ro",
        OPENLIT_IMAGE,
        "/app/opamp/otelcontribcol", "validate", "--config=/etc/otel/config.yaml"
      ]
      run!(command, environment: compose_environment, timeout_seconds: 600)
    end

    def run!(command, environment:, timeout_seconds:, allow_failure: false)
      result = @runner.capture(environment, *command, timeout_seconds: timeout_seconds)
      return result if result.success? || allow_failure

      message = result.stderr.to_s.lines.last(8).join.strip
      message = "command exited with status #{result.status}" if message.empty?
      raise Error, message
    end

    def compose_service_states
      result = compose!("ps", "--format", "json", timeout_seconds: 60, allow_failure: true)
      return {} unless result.success?

      records = parse_json_records(result.stdout)
      records.each_with_object({}) do |record, output|
        service = record["Service"] || record["service"]
        health = record["Health"] || record["health"]
        state = record["State"] || record["state"]
        output[service] = health.to_s.empty? ? state.to_s.downcase : health.to_s.downcase if service
      end
    end

    def parse_json_records(text)
      parsed = JSON.parse(text)
      return parsed.select { |item| item.is_a?(Hash) } if parsed.is_a?(Array)
      return [parsed] if parsed.is_a?(Hash)

      []
    rescue JSON::ParserError
      text.each_line.map do |line|
        JSON.parse(line)
      rescue JSON::ParserError
        nil
      end.select { |item| item.is_a?(Hash) }
    end

    def wait_for_health!(seconds)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      loop do
        states = compose_service_states
        return if states["clickhouse"] == "healthy" && states["openlit"] == "healthy" &&
                  states["collector"] == "healthy" &&
                  tcp_open?("127.0.0.1", 3000) && otlp_backend_ready?
        raise Error, "OpenLIT services did not become healthy within #{seconds} seconds" if
          Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep 2
      end
    end

    def tcp_open?(host, port)
      Timeout.timeout(0.5) { TCPSocket.new(host, port).close }
      true
    rescue SystemCallError, IOError, Timeout::Error
      false
    end

    def otlp_backend_ready?(port = BACKEND_PORT)
      request = Net::HTTP::Post.new("/v1/traces")
      request["Content-Type"] = "application/x-protobuf"
      request.body = "".b
      http = Net::HTTP.new("127.0.0.1", port)
      http.open_timeout = 0.5
      http.read_timeout = 0.5
      response = http.start { |connection| connection.request(request) }
      response.code.to_i.between?(200, 299)
    rescue SystemCallError, IOError, Timeout::Error, Net::HTTPBadResponse
      false
    end

    def require_healthy!
      current = status
      provider_healthy = current.key?("provider_healthy") ? current["provider_healthy"] : current["healthy"]
      raise Error, "agent-observability provider is not healthy; run start" unless provider_healthy
      privacy_healthy = current.key?("privacy_healthy") ? current["privacy_healthy"] : current["healthy"]
      raise Error, "agent-observability privacy verification is not healthy" unless privacy_healthy
    end

    def identity_adapter
      @project_root.join("capabilities/agent-identity/adapters/agent-identity")
    end

    def identity_status
      result = @runner.capture(
        {}, identity_adapter.to_s, "status", "--json", timeout_seconds: COMMAND_TIMEOUT_SECONDS
      )
      raise Error, "agent-identity status is unavailable" unless result.success?

      data = JSON.parse(result.stdout)
      unless data.is_a?(Hash) && data.fetch("identities", []).is_a?(Array) &&
             data.fetch("identities", []).all? { |identity| identity.is_a?(Hash) }
        raise Error, "agent-identity returned invalid status"
      end

      data
    rescue JSON::ParserError
      raise Error, "agent-identity returned invalid status"
    end

    def project_default_identity
      identity_status.fetch("project_bindings", {})[PROJECT_ID]
    end

    def identity_home(identity)
      result = @runner.capture(
        {}, identity_adapter.to_s, "home", "--alias", identity, "--json",
        timeout_seconds: COMMAND_TIMEOUT_SECONDS
      )
      raise Error, "selected identity is unavailable" unless result.success?

      data = JSON.parse(result.stdout)
      raise Error, "agent-identity returned invalid home metadata" unless data.is_a?(Hash)

      home = data["codex_home"].to_s
      raise Error, "selected identity returned no Codex home" if home.empty?
      raise Error, "selected Codex home does not exist" unless Pathname.new(home).directory?

      home
    rescue JSON::ParserError
      raise Error, "agent-identity returned invalid home metadata"
    end

    def validate_codex_arguments!(arguments)
      arguments.each_with_index do |argument, index|
        if %w[-C --cd --remote --remote-auth-token-env].include?(argument) ||
           argument.start_with?("--cd=", "--remote=", "--remote-auth-token-env=")
          raise Error, "Codex project/remote override is not allowed by observed launch"
        end
        next unless %w[-c --config].include?(argument) || argument.start_with?("--config=")

        value = argument.start_with?("--config=") ? argument.delete_prefix("--config=") : arguments[index + 1].to_s
        raise Error, "Codex OTel override is owned by agent-observability" if value.match?(/\Aotel(?:\.|=)/)
      end
    end

    def codex_otel_override
      <<~TOML.gsub(/\s+/, " ").strip
        otel={
          environment="two-head-wu",
          log_user_prompt=false,
          exporter="none",
          metrics_exporter="none",
          trace_exporter={
            otlp-http={
              endpoint="http://127.0.0.1:#{FRONTEND_PORT}/v1/traces",
              protocol="binary"
            }
          },
          span_attributes={
            "project.id"="two-head-wu",
            "agent.logical_identity"="two-head-wu-codex",
            "agent.runtime"="codex",
            "runtime.surface"="#{RUNTIME_SURFACE}",
            "observability.schema"="#{SCHEMA_VERSION}"
          }
        }
      TOML
    end

    def provider_environment
      environment_file.each_line(chomp: true).each_with_object({}) do |line, output|
        next if line.empty? || line.start_with?("#")
        key, value = line.split("=", 2)
        output[key] = value if key && value
      end
    end

    def clickhouse_query(sql)
      credentials = provider_environment
      %w[OPENLIT_DB_USER OPENLIT_DB_PASSWORD OPENLIT_DB_NAME].each do |key|
        raise Error, "provider environment is missing #{key}" if credentials[key].to_s.empty?
      end
      command = [
        *compose_command,
        "--env-file", environment_file.to_s,
        "-f", compose_file.to_s,
        "exec", "-T", "clickhouse",
        "clickhouse-client",
        "--user", credentials.fetch("OPENLIT_DB_USER"),
        "--password", credentials.fetch("OPENLIT_DB_PASSWORD"),
        "--database", credentials.fetch("OPENLIT_DB_NAME"),
        "--format", "JSON",
        "--query", sql
      ]
      result = run!(command, environment: compose_environment, timeout_seconds: 120)
      payload = JSON.parse(result.stdout)
      unless payload.is_a?(Hash)
        raise Error, "ClickHouse returned an invalid response shape"
      end
      rows = payload["data"]
      unless rows.is_a?(Array) && rows.all? { |row| row.is_a?(Hash) }
        raise Error, "ClickHouse returned an invalid response shape"
      end
      rows
    rescue JSON::ParserError
      raise Error, "ClickHouse returned invalid JSON"
    end

    def database_count_value(row, key)
      value = row.fetch(key)
      count = value.is_a?(Integer) ? value : Integer(value, 10)
      raise Error, "ClickHouse returned an invalid #{key} count" if count.negative?

      count
    rescue KeyError, ArgumentError, TypeError
      raise Error, "ClickHouse returned an invalid #{key} count"
    end

    def database_counts
      rows = clickhouse_query(<<~SQL)
        SELECT
          (SELECT count() FROM otel_traces) AS traces,
          (SELECT count() FROM otel_logs WHERE ServiceName = 'codex-cli') AS logs
      SQL
      row = rows.first || {}
      {
        "traces" => database_count_value(row, "traces"),
        "logs" => database_count_value(row, "logs")
      }
    rescue Error
      { "traces" => nil, "logs" => nil }
    end

    def database_privacy_counts
      rows = clickhouse_query(<<~SQL)
        SELECT
          countIf(
            SpanAttributes['project.id'] = '' OR
            NOT match(SpanAttributes['project.id'], '^[a-z0-9][a-z0-9._-]{0,79}$') OR
            SpanAttributes['agent.logical_identity'] != '#{LOGICAL_IDENTITY}' OR
            SpanAttributes['agent.runtime'] != '#{RUNTIME_ID}'
          ) AS unscoped_rows,
          countIf(StatusMessage != '') AS nonempty_status_message_rows,
          countIf(
            arrayExists(key -> match(key, '(^|\\.)(auth|credential|email|account|user|prompt|message|content|body|arguments|output|command)(\\.|$)'), mapKeys(SpanAttributes)) OR
            arrayExists(event -> arrayExists(key -> match(key, '(^|\\.)(auth|credential|email|account|user|prompt|message|content|body|arguments|output|command)(\\.|$)'), mapKeys(event)), `Events.Attributes`)
          ) AS forbidden_attribute_rows
        FROM otel_traces
      SQL
      row = rows.first || {}
      result = {
        "unscoped_rows" => database_count_value(row, "unscoped_rows"),
        "nonempty_status_message_rows" => database_count_value(row, "nonempty_status_message_rows"),
        "forbidden_attribute_rows" => database_count_value(row, "forbidden_attribute_rows")
      }
      result["passed"] = result.values.all?(&:zero?)
      result
    rescue Error
      {
        "unscoped_rows" => nil,
        "nonempty_status_message_rows" => nil,
        "forbidden_attribute_rows" => nil,
        "passed" => false
      }
    end

    def flattened_source(days)
      <<~SQL
        FROM
        (
          SELECT
            Timestamp,
            TraceId,
            SpanAttributes,
            arrayJoin(arrayConcat([SpanAttributes], `Events.Attributes`)) AS attrs
          FROM otel_traces
          WHERE Timestamp >= now() - INTERVAL #{days} DAY
            AND SpanAttributes['agent.logical_identity'] = '#{LOGICAL_IDENTITY}'
            AND SpanAttributes['agent.runtime'] = '#{RUNTIME_ID}'
        )
      SQL
    end

    def query_summary(days)
      tokens = clickhouse_query(<<~SQL).first || {}
        SELECT
          countIf(attrs['codex.usage.total_tokens'] != '') AS token_observations,
          sum(toUInt64OrZero(attrs['gen_ai.usage.input_tokens'])) AS input_tokens,
          sum(toUInt64OrZero(attrs['gen_ai.usage.cache_read.input_tokens'])) AS cached_input_tokens,
          sum(toUInt64OrZero(attrs['gen_ai.usage.cache_write.input_tokens'])) AS cache_write_input_tokens,
          sum(toUInt64OrZero(attrs['gen_ai.usage.output_tokens'])) AS output_tokens,
          sum(toUInt64OrZero(attrs['codex.usage.reasoning_output_tokens'])) AS reasoning_output_tokens,
          sum(toUInt64OrZero(attrs['codex.usage.total_tokens'])) AS total_tokens
        #{flattened_source(days)}
      SQL
      tools = clickhouse_query(<<~SQL).first || {}
        SELECT
          countIf(attrs['event.name'] = 'codex.tool_result') AS tool_calls,
          countIf(attrs['event.name'] = 'codex.tool_result' AND attrs['success'] = 'false') AS failed_tool_calls,
          sumIf(toUInt64OrZero(attrs['duration_ms']), attrs['event.name'] = 'codex.tool_result') AS tool_duration_ms
        #{flattened_source(days)}
      SQL
      sessions = clickhouse_query(<<~SQL).first || {}
        SELECT
          uniqExact(TraceId) AS traces,
          uniqExactIf(attrs['conversation.id'], attrs['conversation.id'] != '') AS conversations
        #{flattened_source(days)}
      SQL
      [sessions.merge(tokens).merge(tools)]
    end

    def query_tokens(days, group_expression, group_name, limit)
      clickhouse_query(<<~SQL)
        SELECT
          #{group_expression} AS `#{group_name}`,
          countIf(attrs['codex.usage.total_tokens'] != '') AS observations,
          sum(toUInt64OrZero(attrs['gen_ai.usage.input_tokens'])) AS input_tokens,
          sum(toUInt64OrZero(attrs['gen_ai.usage.cache_read.input_tokens'])) AS cached_input_tokens,
          sum(toUInt64OrZero(attrs['gen_ai.usage.output_tokens'])) AS output_tokens,
          sum(toUInt64OrZero(attrs['codex.usage.reasoning_output_tokens'])) AS reasoning_output_tokens,
          sum(toUInt64OrZero(attrs['codex.usage.total_tokens'])) AS total_tokens
        #{flattened_source(days)}
        GROUP BY `#{group_name}`
        ORDER BY total_tokens DESC
        LIMIT #{limit}
      SQL
    end

    def query_projects(days, limit)
      rows = clickhouse_query(<<~SQL)
        WITH project_mapping AS
        (
          SELECT
            attrs['conversation.id'] AS conversation_id,
            argMax(SpanAttributes['project.id'], Timestamp) AS mapped_project_id
          #{flattened_source(days)}
          WHERE attrs['event.name'] = 'two_head_wu.session_project'
            AND attrs['conversation.id'] != ''
          GROUP BY conversation_id
        ),
        per_trace AS
        (
          SELECT
            TraceId,
            coalesce(
              nullIf(anyIf(attrs['conversation.id'], attrs['conversation.id'] != ''), ''),
              nullIf(anyIf(SpanAttributes['conversation.id'], SpanAttributes['conversation.id'] != ''), ''),
              ''
            ) AS conversation_id,
            coalesce(
              nullIf(anyIf(SpanAttributes['project.id'], SpanAttributes['project.id'] != 'local-unclassified'), ''),
              'local-unclassified'
            ) AS observed_project_id,
            countIf(attrs['codex.usage.total_tokens'] != '') AS observations,
            sum(toUInt64OrZero(attrs['gen_ai.usage.input_tokens'])) AS input_tokens,
            sum(toUInt64OrZero(attrs['gen_ai.usage.cache_read.input_tokens'])) AS cached_input_tokens,
            sum(toUInt64OrZero(attrs['gen_ai.usage.output_tokens'])) AS output_tokens,
            sum(toUInt64OrZero(attrs['codex.usage.reasoning_output_tokens'])) AS reasoning_output_tokens,
            sum(toUInt64OrZero(attrs['codex.usage.total_tokens'])) AS total_tokens
          #{flattened_source(days)}
          GROUP BY TraceId
        ),
        attributed AS
        (
          SELECT
            per_trace.TraceId AS TraceId,
            per_trace.conversation_id AS conversation_id,
            coalesce(nullIf(project_mapping.mapped_project_id, ''), per_trace.observed_project_id) AS project_id,
            per_trace.observations AS observations,
            per_trace.input_tokens AS input_tokens,
            per_trace.cached_input_tokens AS cached_input_tokens,
            per_trace.output_tokens AS output_tokens,
            per_trace.reasoning_output_tokens AS reasoning_output_tokens,
            per_trace.total_tokens AS total_tokens
          FROM per_trace
          LEFT JOIN project_mapping USING (conversation_id)
          WHERE per_trace.observations > 0
        )
        SELECT
          project_id,
          uniqExactIf(conversation_id, conversation_id != '') AS conversations,
          sum(observations) AS observations,
          sum(input_tokens) AS input_tokens,
          sum(cached_input_tokens) AS cached_input_tokens,
          sum(output_tokens) AS output_tokens,
          sum(reasoning_output_tokens) AS reasoning_output_tokens,
          sum(total_tokens) AS total_tokens
        FROM attributed
        GROUP BY project_id
        ORDER BY total_tokens DESC
        LIMIT #{limit}
      SQL
      labels = project_labels
      rows.each do |row|
        row["project_name"] = labels.fetch(row["project_id"], row["project_id"])
      end
      rows
    end

    def verification_evidence(project_id, conversation_id)
      row = clickhouse_query(<<~SQL).first || {}
        WITH project_mapping AS
        (
          SELECT
            attrs['conversation.id'] AS conversation_id,
            argMax(SpanAttributes['project.id'], Timestamp) AS mapped_project_id
          #{flattened_source(1)}
          WHERE attrs['event.name'] = 'two_head_wu.session_project'
            AND attrs['conversation.id'] = '#{conversation_id}'
          GROUP BY conversation_id
        ),
        per_trace AS
        (
          SELECT
            TraceId,
            coalesce(
              nullIf(anyIf(attrs['conversation.id'], attrs['conversation.id'] != ''), ''),
              nullIf(anyIf(SpanAttributes['conversation.id'], SpanAttributes['conversation.id'] != ''), ''),
              ''
            ) AS conversation_id,
            countIf(attrs['codex.usage.total_tokens'] != '') AS token_observations,
            sum(toUInt64OrZero(attrs['codex.usage.total_tokens'])) AS total_tokens
          #{flattened_source(1)}
          GROUP BY TraceId
        )
        SELECT
          uniqExact(project_mapping.conversation_id) AS conversation_count,
          sum(per_trace.token_observations) AS token_observations,
          sum(per_trace.total_tokens) AS total_tokens
        FROM project_mapping
        INNER JOIN per_trace USING (conversation_id)
        WHERE project_mapping.mapped_project_id = '#{project_id}'
          AND per_trace.conversation_id = '#{conversation_id}'
          AND per_trace.token_observations > 0
      SQL
      conversations = row.fetch("conversation_count", 0).to_i
      observations = row.fetch("token_observations", 0).to_i
      {
        "verified" => conversations.positive? && observations.positive?,
        "project_id" => project_id,
        "conversation_id" => conversation_id,
        "conversation_count" => conversations,
        "token_observations" => observations,
        "total_tokens" => row.fetch("total_tokens", 0).to_i
      }
    end

    def query_models(days, limit)
      clickhouse_query(<<~SQL)
        WITH per_trace AS
        (
          SELECT
            TraceId,
            coalesce(
              nullIf(anyIf(attrs['gen_ai.request.model'], attrs['gen_ai.request.model'] != ''), ''),
              nullIf(anyIf(attrs['model'], attrs['model'] != ''), ''),
              nullIf(anyIf(SpanAttributes['model'], SpanAttributes['model'] != ''), ''),
              'unknown'
            ) AS model,
            countIf(attrs['codex.usage.total_tokens'] != '') AS trace_observations,
            sum(toUInt64OrZero(attrs['gen_ai.usage.input_tokens'])) AS trace_input_tokens,
            sum(toUInt64OrZero(attrs['gen_ai.usage.cache_read.input_tokens'])) AS trace_cached_input_tokens,
            sum(toUInt64OrZero(attrs['gen_ai.usage.output_tokens'])) AS trace_output_tokens,
            sum(toUInt64OrZero(attrs['codex.usage.reasoning_output_tokens'])) AS trace_reasoning_output_tokens,
            sum(toUInt64OrZero(attrs['codex.usage.total_tokens'])) AS trace_total_tokens
          #{flattened_source(days)}
          GROUP BY TraceId
        )
        SELECT
          model,
          sum(trace_observations) AS observations,
          sum(trace_input_tokens) AS input_tokens,
          sum(trace_cached_input_tokens) AS cached_input_tokens,
          sum(trace_output_tokens) AS output_tokens,
          sum(trace_reasoning_output_tokens) AS reasoning_output_tokens,
          sum(trace_total_tokens) AS total_tokens
        FROM per_trace
        WHERE trace_observations > 0
        GROUP BY model
        ORDER BY total_tokens DESC
        LIMIT #{limit}
      SQL
    end

    def query_tools(days, limit)
      clickhouse_query(<<~SQL)
        SELECT
          if(attrs['tool_namespace'] = '', attrs['tool_name'], concat(attrs['tool_namespace'], '.', attrs['tool_name'])) AS tool,
          count() AS calls,
          countIf(attrs['success'] = 'false') AS failures,
          sum(toUInt64OrZero(attrs['duration_ms'])) AS duration_ms,
          sum(toUInt64OrZero(attrs['arguments_length'])) AS argument_bytes,
          sum(toUInt64OrZero(attrs['output_length'])) AS output_bytes
        #{flattened_source(days)}
        WHERE attrs['event.name'] = 'codex.tool_result'
        GROUP BY tool
        ORDER BY calls DESC, duration_ms DESC
        LIMIT #{limit}
      SQL
    end

    def query_capabilities(days, limit)
      rows = clickhouse_query(<<~SQL)
        SELECT
          attrs['capability.id'] AS capability,
          attrs['interface.id'] AS interface,
          count() AS calls,
          countIf(attrs['success'] = 'false') AS failures,
          sum(toUInt64OrZero(attrs['duration_ms'])) AS duration_ms
        #{flattened_source(days)}
        WHERE attrs['event.name'] = 'two_head_wu.capability_invocation'
          AND attrs['capability.id'] != ''
        GROUP BY capability, interface
        ORDER BY calls DESC, duration_ms DESC
        LIMIT #{limit}
      SQL
      allowed = registered_capability_ids
      rows.select { |row| allowed.include?(row["capability"]) }
    end

    def query_surfaces(days, limit)
      clickhouse_query(<<~SQL)
        WITH per_trace AS
        (
          SELECT
            TraceId,
            coalesce(nullIf(anyIf(attrs['originator'], attrs['originator'] != ''), ''), 'unknown') AS originator,
            coalesce(nullIf(anyIf(attrs['terminal.type'], attrs['terminal.type'] != ''), ''), 'unknown') AS terminal_type,
            countIf(attrs['codex.usage.total_tokens'] != '') AS observations,
            sum(toUInt64OrZero(attrs['codex.usage.total_tokens'])) AS total_tokens
          #{flattened_source(days)}
          GROUP BY TraceId
        )
        SELECT originator, terminal_type, count() AS traces, sum(observations) AS observations,
               sum(total_tokens) AS total_tokens
        FROM per_trace
        GROUP BY originator, terminal_type
        ORDER BY total_tokens DESC, traces DESC
        LIMIT #{limit}
      SQL
    end
  end

  class AgentObservabilityCLI
    def initialize(arguments, environment: ENV)
      @arguments = arguments.dup
      @environment = environment
    end

    def run
      command = implied_command || @arguments.shift || "help"
      return help if %w[help --help -h].include?(command)

      common, command_arguments = split_common(@arguments)
      observability = AgentObservability.new(
        project_root: common["project_root"],
        data_root: common["data_root"],
        environment: @environment
      )
      result = case command
               when "configure" then no_arguments!(command_arguments) { observability.configure }
               when "install" then no_arguments!(command_arguments) { observability.install }
               when "uninstall" then no_arguments!(command_arguments) { observability.uninstall }
               when "start" then start(observability, command_arguments)
               when "stop" then no_arguments!(command_arguments) { observability.stop }
               when "status" then no_arguments!(command_arguments) { observability.status }
               when "integration-status" then no_arguments!(command_arguments) { observability.integration_status }
               when "coverage" then no_arguments!(command_arguments) { observability.coverage }
               when "query" then query(observability, command_arguments)
               when "verify" then verify(observability, command_arguments)
               when "launch" then launch(observability, command_arguments)
               when "notify" then notify(observability, command_arguments)
               else raise AgentObservability::Error, "unknown command: #{command}"
               end
      print_result(result, common["json"]) if result
      0
    rescue AgentObservability::Error, OptionParser::ParseError, KeyError => error
      warn "Error: #{error.message}"
      2
    end

    private

    def implied_command
      AgentObservability::INTERFACE_COMMANDS[@environment["TWO_HEAD_WU_CAPABILITY_INTERFACE_ID"]]
    end

    def split_common(arguments)
      options = { "json" => false }
      remaining = []
      index = 0
      while index < arguments.length
        argument = arguments[index]
        case argument
        when "--json"
          options["json"] = true
        when "--project-root", "--data-root"
          value = arguments[index + 1]
          raise OptionParser::MissingArgument, argument unless value
          options[argument.delete_prefix("--").tr("-", "_")] = value
          index += 1
        else
          remaining << argument
        end
        index += 1
      end
      [options, remaining]
    end

    def no_arguments!(arguments)
      raise OptionParser::InvalidOption, arguments.join(" ") unless arguments.empty?
      yield
    end

    def start(observability, arguments)
      wait = 240
      parser = OptionParser.new { |item| item.on("--wait SECONDS", Integer) { |value| wait = value } }
      parser.parse!(arguments)
      raise OptionParser::InvalidOption, arguments.join(" ") unless arguments.empty?
      raise AgentObservability::Error, "wait must be between 30 and 900 seconds" unless wait.between?(30, 900)
      observability.start(wait_seconds: wait)
    end

    def query(observability, arguments)
      options = { "days" => AgentObservability::DEFAULT_QUERY_DAYS, "group_by" => "summary",
                  "limit" => AgentObservability::DEFAULT_QUERY_LIMIT }
      parser = OptionParser.new do |item|
        item.on("--days DAYS", Integer) { |value| options["days"] = value }
        item.on("--group-by GROUP") { |value| options["group_by"] = value }
        item.on("--limit COUNT", Integer) { |value| options["limit"] = value }
      end
      parser.parse!(arguments)
      raise OptionParser::InvalidOption, arguments.join(" ") unless arguments.empty?
      observability.query(days: options["days"], group_by: options["group_by"], limit: options["limit"])
    end

    def verify(observability, arguments)
      project_id = nil
      conversation_id = nil
      parser = OptionParser.new do |item|
        item.on("--project-id ID") { |value| project_id = value }
        item.on("--conversation-id UUID") { |value| conversation_id = value }
      end
      parser.parse!(arguments)
      raise OptionParser::MissingArgument, "--project-id" if project_id.to_s.empty?
      raise OptionParser::MissingArgument, "--conversation-id" if conversation_id.to_s.empty?
      raise OptionParser::InvalidOption, arguments.join(" ") unless arguments.empty?
      observability.verify(project_id: project_id, conversation_id: conversation_id)
    end

    def launch(observability, arguments)
      separator = arguments.index("--")
      codex_arguments = separator ? arguments.slice!(separator + 1, arguments.length) : []
      arguments.delete_at(separator) if separator
      identity = nil
      parser = OptionParser.new { |item| item.on("--identity ALIAS") { |value| identity = value } }
      parser.parse!(arguments)
      raise OptionParser::InvalidOption, arguments.join(" ") unless arguments.empty?
      observability.launch(identity: identity, codex_arguments: codex_arguments)
      nil
    end

    def notify(observability, arguments)
      state_key = nil
      parser = OptionParser.new { |item| item.on("--state-key KEY") { |value| state_key = value } }
      parser.order!(arguments)
      raise OptionParser::MissingArgument, "--state-key" if state_key.to_s.empty?
      raise OptionParser::MissingArgument, "PAYLOAD" unless arguments.length == 1
      observability.handle_notify(state_key: state_key, payload_text: arguments.fetch(0))
      nil
    end

    def print_result(result, json)
      if json
        puts JSON.generate(result)
      else
        puts YAML.dump(result)
      end
    end

    def help
      puts <<~HELP
        Usage: agent-observability COMMAND [OPTIONS]

          configure [--json]
          install [--json]
          uninstall [--json]
          start [--wait SECONDS] [--json]
          stop [--json]
          status [--json]
          integration-status [--json]
          coverage [--json]
          verify --project-id ID --conversation-id UUID [--json]
          query [--days 30] [--group-by summary|day|project|model|tool|capability|surface] [--limit 100] [--json]
          launch [--identity ALIAS] -- [CODEX_ARGUMENTS...]

        Common options:
          --project-root PATH
          --data-root PATH
          --json

        Install integrates every registered local Codex identity and a launchd
        socket-activated OTLP proxy. Provider services start on first telemetry,
        not at boot or login. Stop and uninstall preserve provider data.
      HELP
      0
    end
  end
end
