# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "pathname"
require "tmpdir"

require_relative "../lib/agent_observability"
require_relative "../lib/lazy_otlp_proxy"

class AgentObservabilityTest < Minitest::Test
  ROOT = Pathname.new(__dir__).join("../../..").realpath
  PACKAGE = ROOT.join("capabilities/agent-observability")

  class LaunchProbe < TwoHeadWu::AgentObservability
    attr_reader :captured_environment, :captured_command

    def initialize(home:, **options)
      @probe_home = home
      super(**options)
    end

    def status
      { "healthy" => true }
    end

    def identity_home(_identity)
      @probe_home.to_s
    end

    def project_default_identity
      "default"
    end

    def command_path(command)
      return "/usr/bin/true" if command == "codex"
      super
    end

    def exec(environment, *command)
      @captured_environment = environment
      @captured_command = command
      :captured
    end
  end

  class QueryProbe < TwoHeadWu::AgentObservability
    attr_reader :queries

    def initialize(**options)
      @queries = []
      super
    end

    def status
      { "healthy" => true }
    end

    def clickhouse_query(sql)
      @queries << sql
      [{ "value" => 1 }]
    end
  end

  class NotifyProbe < TwoHeadWu::AgentObservability
    attr_reader :mapping, :forwarded

    def request_provider_start
      true
    end

    def send_project_mapping(conversation_id, project)
      @mapping = [conversation_id, project]
      true
    end

    def forward_previous_notify(state_key, payload_text)
      @forwarded = [state_key, payload_text]
      true
    end
  end

  class UninstallProbe < TwoHeadWu::AgentObservability
    attr_reader :unload_called

    def initialize(fail_unload: false, **options)
      @fail_unload = fail_unload
      super(**options)
    end

    def unload_launch_agent!
      @unload_called = true
      raise Error, "simulated unload failure" if @fail_unload
    end
  end

  class WaitingProxy < TwoHeadWu::LazyOtlpProxy
    attr_reader :forwarded, :provider_start_count

    def initialize(**options)
      super
      @release = Queue.new
      @forwarded = Queue.new
      @provider_start_count = 0
    end

    def release_backend
      @release << true
    end

    private

    def request_provider_start
      @provider_start_count += 1
    end

    def wait_for_backend
      @release.pop
    end

    def forward(item)
      @forwarded << item
    end
  end

  class BootstrapFailureProbe < TwoHeadWu::AgentObservability
    def otlp_backend_ready?(_port = BACKEND_PORT)
      false
    end

    def runtime_package_root
      Pathname.new("/definitely-missing/two-head-wu-agent-observability")
    end
  end

  class NeverReadyProxy < TwoHeadWu::LazyOtlpProxy
    private

    def request_provider_start
      nil
    end

    def backend_open?
      false
    end
  end

  class ProxySignalProbe
    attr_reader :signal_count, :gaps

    def initialize(signal: true)
      @signal = signal
      @signal_count = 0
      @gaps = []
    end

    def signal_provider_trigger
      @signal_count += 1
      @signal
    end

    def request_provider_start
      raise "launchd proxy must not use the external-volume bootstrap fallback"
    end

    def record_coverage_gap(reason, **details)
      @gaps << [reason, details]
    end
  end

  class ResilientProxy < TwoHeadWu::LazyOtlpProxy
    attr_reader :forwarded

    def initialize(**options)
      @forwarded = Queue.new
      super
    end

    private

    def request_provider_start
      true
    end

    def wait_for_backend
      true
    end

    def forward(item)
      raise "simulated worker failure" if item.fetch("body") == "bad"

      @forwarded << item
    end
  end

  class VerificationProbe < TwoHeadWu::AgentObservability
    def status
      { "healthy" => true, "privacy" => { "passed" => true } }
    end

    def identity_status
      { "identities" => [{ "configured" => true }] }
    end

    def integration_status
      { "installed" => true, "configured_home_count" => 1 }
    end

    def verification_evidence(project_id, conversation_id)
      {
        "verified" => true,
        "project_id" => project_id,
        "conversation_id" => conversation_id,
        "conversation_count" => 1,
        "token_observations" => 1,
        "total_tokens" => 10
      }
    end
  end

  class SurfaceWriteFailureProbe < TwoHeadWu::AgentObservability
    def initialize(*args, **kwargs)
      @fail_settings = false
      super(*args, **kwargs)
    end

    def enable_settings_failure
      @fail_settings = true
    end

    def atomic_write(path, content, mode:)
      raise Error, "simulated VS Code settings failure" if @fail_settings && path.basename.to_s == "settings.json"

      super
    end
  end

  class InstallProbe < TwoHeadWu::AgentObservability
    attr_accessor :homes, :fail_surfaces

    def initialize(homes:, fail_surfaces: false, **options)
      @homes = homes
      @fail_surfaces = fail_surfaces
      super(**options)
    end

    def identity_status
      { "identities" => homes.keys.map { |id| { "id" => id, "configured" => true } } }
    end

    def identity_home(identity)
      homes.fetch(identity).to_s
    end

    def install_runtime_bundle!
      true
    end

    def install_launch_surfaces!(state)
      raise Error, "simulated launch surface failure" if fail_surfaces

      state["launch_surfaces"] = { "test" => true }
      true
    end

    def install_launch_agent!
      true
    end

    def bootout_launch_agent!
      Result.new(stdout: "", stderr: "", status: 0)
    end

    def launch_agent_loaded?
      false
    end

    def integration_status
      { "installed" => true, "configured_home_count" => homes.length }
    end
  end

  class ProviderStatusProbe < TwoHeadWu::AgentObservability
    attr_accessor :integration_installed, :database_available, :privacy_passed

    def command_available?(_command)
      true
    end

    def colima_running?
      true
    end

    def compose_command
      ["/usr/bin/true"]
    end

    def compose_service_states
      { "clickhouse" => "healthy", "collector" => "healthy", "openlit" => "healthy" }
    end

    def tcp_open?(_host, _port)
      true
    end

    def otlp_backend_ready?(_port = BACKEND_PORT)
      true
    end

    def database_counts
      return { "traces" => nil, "logs" => nil } if database_available == false

      { "traces" => 1, "logs" => 0 }
    end

    def database_privacy_counts
      { "passed" => privacy_passed != false }
    end

    def integration_status
      {
        "installed" => integration_installed,
        "configured_home_count" => integration_installed ? 1 : 0,
        "launch_agent_loaded" => integration_installed,
        "launch_agent_current" => integration_installed
      }
    end
  end

  class IntegrationStatusProbe < TwoHeadWu::AgentObservability
    attr_accessor :homes

    def initialize(homes:, **options)
      @homes = homes
      super(**options)
    end

    def identity_status
      { "identities" => homes.keys.map { |id| { "id" => id, "configured" => true } } }
    end

    def identity_home(identity)
      homes.fetch(identity).to_s
    end

    def launch_surface_restore_plans(_state)
      [{}, {}]
    end

    def launch_agent_current?
      true
    end

    def launch_agent_loaded?
      true
    end
  end

  class ConcurrentProjectMapProbe < TwoHeadWu::AgentObservability
    attr_reader :maximum_concurrent_loads

    def initialize(**options)
      @load_mutex = Mutex.new
      @active_loads = 0
      @maximum_concurrent_loads = 0
      super
    end

    def load_project_map
      @load_mutex.synchronize do
        @active_loads += 1
        @maximum_concurrent_loads = [@maximum_concurrent_loads, @active_loads].max
      end
      sleep 0.03
      super
    ensure
      @load_mutex.synchronize { @active_loads -= 1 }
    end
  end

  class ProviderLifecycleProbe < TwoHeadWu::AgentObservability
    def start_without_lock(wait_seconds:, pull:)
      { "wait_seconds" => wait_seconds, "pull" => pull }
    end

    def stop_without_lock
      { "result" => "stopped" }
    end
  end

  def setup
    @temporary = Pathname.new(Dir.mktmpdir("agent-observability"))
    @project = @temporary.join("two-head-wu")
    @project.join("var/large-assets").mkpath
    @environment = {
      "PATH" => ENV.fetch("PATH"),
      "HOME" => @temporary.join("home").tap(&:mkpath).to_s,
      "TWO_HEAD_WU_OBSERVABILITY_ALLOW_NON_EXTERNAL_FOR_TEST" => "1"
    }
    @observability = TwoHeadWu::AgentObservability.new(
      project_root: @project,
      package_root: PACKAGE,
      environment: @environment
    )
  end

  def teardown
    FileUtils.rm_rf(@temporary)
  end

  def test_configure_creates_private_external_state_without_touching_codex_config
    codex_config = @temporary.join("identity/config.toml")
    codex_config.dirname.mkpath
    codex_config.write("model = \"unchanged\"\n")
    before = codex_config.read

    first = @observability.configure
    env_file = @project.join("var/large-assets/agent-observability/config/provider.env")
    manifest = @project.join("var/large-assets/agent-observability/config/runtime.json")
    password_line = env_file.each_line.find { |line| line.start_with?("OPENLIT_DB_PASSWORD=") }

    assert_equal true, first.fetch("created_secret")
    assert_equal 0o600, env_file.stat.mode & 0o777
    assert_match(/\AOPENLIT_DB_PASSWORD=[0-9a-f]{64}\n\z/, password_line)
    assert_equal "two-head-wu", JSON.parse(manifest.read).fetch("project")
    assert_equal before, codex_config.read

    second = @observability.configure
    assert_equal false, second.fetch("created_secret")
    assert_equal password_line, env_file.each_line.find { |line| line.start_with?("OPENLIT_DB_PASSWORD=") }
  end

  def test_runtime_manifest_rejects_valid_json_with_the_wrong_shape
    @observability.configure
    manifest = @observability.send(:runtime_manifest)
    manifest.write("[]\n")
    manifest.chmod(0o600)

    error = assert_raises(TwoHeadWu::AgentObservability::Error) do
      @observability.send(:require_configured!)
    end

    assert_includes error.message, "runtime manifest is invalid"
  end

  def test_integration_mutations_refuse_a_concurrent_process
    lock_path = @observability.send(:local_state_root).join("integration.lock")
    lock_path.dirname.mkpath
    lock = File.open(lock_path, File::RDWR | File::CREAT, 0o600)
    assert lock.flock(File::LOCK_EX | File::LOCK_NB)

    error = assert_raises(TwoHeadWu::AgentObservability::Error) { @observability.configure }

    assert_includes error.message, "integration mutation is in progress"
    refute @observability.send(:runtime_manifest).exist?
  ensure
    lock&.flock(File::LOCK_UN)
    lock&.close
  end

  def test_provider_start_and_stop_refuse_a_concurrent_lifecycle_mutation
    probe = ProviderLifecycleProbe.new(
      project_root: @project, package_root: PACKAGE, environment: @environment
    )
    probe.configure
    lock_path = probe.send(:local_state_root).join("provider-lifecycle.lock")
    lock = File.open(lock_path, File::RDWR | File::CREAT, 0o600)
    assert lock.flock(File::LOCK_EX | File::LOCK_NB)

    start_error = assert_raises(TwoHeadWu::AgentObservability::Error) { probe.start }
    stop_error = assert_raises(TwoHeadWu::AgentObservability::Error) { probe.stop }

    assert_includes start_error.message, "integration mutation is in progress"
    assert_includes stop_error.message, "integration mutation is in progress"
  ensure
    lock&.flock(File::LOCK_UN)
    lock&.close
  end

  def test_stop_attempts_colima_shutdown_but_does_not_hide_compose_failure
    probe = TwoHeadWu::AgentObservability.new(
      project_root: @project, package_root: PACKAGE, environment: @environment
    )
    probe.configure
    colima_stop_called = false
    probe.define_singleton_method(:stop_proxy_process!) { true }
    probe.define_singleton_method(:colima_running?) { true }
    probe.define_singleton_method(:compose!) do |*_arguments, timeout_seconds:, allow_failure: false|
      raise "unexpected allow_failure" if allow_failure
      raise "missing timeout" unless timeout_seconds
      raise TwoHeadWu::AgentObservability::Error, "simulated compose stop failure"
    end
    probe.define_singleton_method(:run_colima!) do |*_arguments, timeout_seconds:, allow_failure: false|
      raise "unexpected allow_failure" if allow_failure
      raise "missing timeout" unless timeout_seconds
      colima_stop_called = true
      TwoHeadWu::AgentObservability::Result.new(stdout: "", stderr: "", status: 0)
    end

    error = assert_raises(TwoHeadWu::AgentObservability::Error) { probe.stop }

    assert_equal true, colima_stop_called
    assert_includes error.message, "simulated compose stop failure"
  end

  def test_status_does_not_report_end_to_end_health_when_integration_is_broken
    probe = ProviderStatusProbe.new(
      project_root: @project, package_root: PACKAGE, environment: @environment
    )
    probe.configure
    probe.integration_installed = false

    status = probe.status

    assert_equal true, status.fetch("provider_healthy")
    assert_equal false, status.fetch("healthy")
    assert_equal false, status.dig("integration", "installed")
    assert_nil status.dig("endpoints", "otlp_http_frontend")
  end

  def test_status_is_unhealthy_when_database_queries_fail_despite_healthy_ports
    probe = ProviderStatusProbe.new(
      project_root: @project, package_root: PACKAGE, environment: @environment
    )
    probe.configure
    probe.integration_installed = true
    probe.database_available = false

    status = probe.status

    assert_equal false, status.fetch("database_healthy")
    assert_equal false, status.fetch("provider_healthy")
    assert_equal false, status.fetch("healthy")
  end

  def test_status_is_unhealthy_when_privacy_verification_fails
    probe = ProviderStatusProbe.new(
      project_root: @project, package_root: PACKAGE, environment: @environment
    )
    probe.configure
    probe.integration_installed = true
    probe.privacy_passed = false

    status = probe.status

    assert_equal true, status.fetch("database_healthy")
    assert_equal true, status.fetch("provider_healthy")
    assert_equal false, status.fetch("privacy_healthy")
    assert_equal false, status.fetch("healthy")
  end

  def test_otlp_backend_readiness_requires_a_successful_http_response
    listener = TCPServer.new("127.0.0.1", 0)
    responses = [500, 200]
    server = Thread.new do
      responses.each do |status|
        socket = listener.accept
        request = +""
        request << socket.readpartial(4096) until request.include?("\r\n\r\n")
        reason = status == 200 ? "OK" : "Internal Server Error"
        socket.write("HTTP/1.1 #{status} #{reason}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        socket.close
      end
    end

    refute @observability.send(:otlp_backend_ready?, listener.addr.fetch(1))
    assert @observability.send(:otlp_backend_ready?, listener.addr.fetch(1))
    Timeout.timeout(1) { server.join }
  ensure
    listener&.close
    server&.kill
    server&.join
  end

  def test_external_status_json_with_the_wrong_shape_is_handled_as_contract_failure
    runner = Object.new
    runner.define_singleton_method(:capture) do |_environment, *_command, **_options|
      TwoHeadWu::AgentObservability::Result.new(stdout: "[]\n", stderr: "", status: 0)
    end
    probe = TwoHeadWu::AgentObservability.new(
      project_root: @project, package_root: PACKAGE, environment: @environment, runner: runner
    )
    probe.define_singleton_method(:command_available?) { |_command| true }

    assert_equal false, probe.send(:colima_running?)
    identity_error = assert_raises(TwoHeadWu::AgentObservability::Error) do
      probe.send(:identity_status)
    end
    assert_includes identity_error.message, "invalid status"
    home_error = assert_raises(TwoHeadWu::AgentObservability::Error) do
      probe.send(:identity_home, "test")
    end
    assert_includes home_error.message, "invalid home metadata"
  end

  def test_registry_and_compose_parsers_ignore_valid_json_or_yaml_scalars
    @project.join("registries").mkpath
    @project.join("catalog").mkpath
    @project.join("registries/projects_registry.yaml").write("[]\n")
    @project.join("catalog/packages_registry.yaml").write("42\n")

    assert_empty @observability.send(:registered_projects)
    assert_empty @observability.send(:registered_capability_ids)
    assert_equal [{ "Service" => "collector" }], @observability.send(
      :parse_json_records, '[1, {"Service":"collector"}, null]'
    )
    assert_equal [{ "Service" => "openlit" }], @observability.send(
      :parse_json_records, "1\n{\"Service\":\"openlit\"}\nnull\n"
    )
  end

  def test_query_refuses_to_run_when_privacy_verification_is_unhealthy
    probe = QueryProbe.new(
      project_root: @project, package_root: PACKAGE, environment: @environment
    )
    probe.define_singleton_method(:status) do
      { "healthy" => false, "provider_healthy" => true, "privacy_healthy" => false }
    end

    error = assert_raises(TwoHeadWu::AgentObservability::Error) { probe.query }

    assert_includes error.message, "privacy verification"
    assert_empty probe.queries
  end

  def test_integration_status_compares_registered_home_paths_not_only_counts
    old_home = @temporary.join("registered-old").tap(&:mkpath)
    new_home = @temporary.join("registered-new").tap(&:mkpath)
    old_home.join("config.toml").write("model = \"old\"\n")
    new_home.join("config.toml").write("model = \"new\"\n")
    probe = IntegrationStatusProbe.new(
      homes: { "old" => old_home },
      project_root: @project, package_root: PACKAGE, environment: @environment
    )
    probe.configure
    probe.send(:install_runtime_bundle!)
    state = { "schema_version" => 1, "homes" => {} }
    probe.send(:install_codex_home!, old_home.to_s, state)

    assert_equal true, probe.integration_status.fetch("installed")
    assert_equal true, probe.integration_status.fetch("runtime_bundle_current")

    probe.homes = { "new" => new_home }
    assert_equal false, probe.integration_status.fetch("installed")
    assert_equal 1, probe.integration_status.fetch("configured_home_count")
  end

  def test_integration_status_detects_runtime_bundle_drift
    home = @temporary.join("runtime-drift-home").tap(&:mkpath)
    home.join("config.toml").write("model = \"safe\"\n")
    probe = IntegrationStatusProbe.new(
      homes: { "only" => home },
      project_root: @project, package_root: PACKAGE, environment: @environment
    )
    probe.configure
    probe.send(:install_runtime_bundle!)
    state = { "schema_version" => 1, "homes" => {} }
    probe.send(:install_codex_home!, home.to_s, state)
    runtime_manifest = probe.send(:runtime_package_root).join("capability.yaml")
    runtime_manifest.chmod(0o600)
    File.open(runtime_manifest, "a") { |file| file.puts("# drift") }

    status = probe.integration_status

    assert_equal false, status.fetch("installed")
    assert_equal false, status.fetch("runtime_bundle_current")
  end

  def test_integration_status_reports_false_for_malformed_recovery_entries
    home = @temporary.join("malformed-state-home").tap(&:mkpath)
    home.join("config.toml").write("model = \"safe\"\n")
    probe = IntegrationStatusProbe.new(
      homes: { "only" => home },
      project_root: @project, package_root: PACKAGE, environment: @environment
    )
    probe.configure
    state_file = probe.send(:integration_state_file)
    state_file.write(JSON.generate("schema_version" => 1, "homes" => { "bad" => {} }))
    state_file.chmod(0o600)

    status = probe.integration_status

    assert_equal false, status.fetch("installed")
    assert_equal 0, status.fetch("configured_home_count")
  end

  def test_managed_codex_config_preserves_existing_notify_in_recovery_state
    @observability.configure
    home = @temporary.join("identity")
    home.mkpath
    config = home.join("config.toml")
    original = "notify = [\"/usr/bin/true\", \"turn-ended\"]\nmodel = \"gpt-test\"\n[features]\nfoo = true\n"
    config.write(original)
    state = { "schema_version" => 1, "homes" => {} }

    @observability.send(:install_codex_home!, home.to_s, state)
    installed = config.read
    stored = JSON.parse(
      @project.join("var/large-assets/agent-observability/config/codex-integration.json").read
    )
    entry = stored.fetch("homes").values.first

    assert_includes installed, TwoHeadWu::AgentObservability::CONFIG_MARKER_BEGIN
    assert_includes installed, "log_user_prompt = false"
    assert_includes installed, "127.0.0.1:4318/v1/traces"
    assert_equal ["/usr/bin/true", "turn-ended"], entry.fetch("previous_notify")
    refute_match(/^prompt\s*=/, installed)
    assert_equal 0o600, config.stat.mode & 0o777

  end

  def test_reinstall_repairs_missing_managed_notify_without_losing_original_recovery_value
    @observability.configure
    home = @temporary.join("identity-repair")
    home.mkpath
    config = home.join("config.toml")
    original_notify = ["/usr/bin/true", "turn-ended"]
    config.write("notify = #{JSON.generate(original_notify)}\nmodel = \"gpt-test\"\n")
    state = { "schema_version" => 1, "homes" => {} }
    @observability.send(:install_codex_home!, home.to_s, state)
    config.write(config.read.lines.reject { |line| line.start_with?("notify = ") }.join)

    @observability.send(:install_codex_home!, home.to_s, state)
    stored = JSON.parse(@observability.send(:integration_state_file).read)
    entry = stored.fetch("homes").values.first

    assert_includes config.read, '"notify"'
    assert_equal original_notify, entry.fetch("previous_notify")
  end

  def test_reinstall_recognizes_only_confined_previous_managed_notify
    @observability.configure
    state_key = "a" * 24
    expected = @observability.send(:managed_notify_command, state_key)
    previous_version = expected.dup
    previous_version[0] = previous_version.fetch(0).sub(
      "/#{TwoHeadWu::AgentObservability::CAPABILITY_VERSION}/", "/0.3.3/"
    )
    spoofed = expected.dup
    spoofed[0] = "/tmp/agent-observability"

    assert @observability.send(:managed_notify_command?, previous_version, state_key)
    refute @observability.send(:managed_notify_command?, spoofed, state_key)
    refute @observability.send(:managed_notify_command?, expected + ["--unexpected"], state_key)
  end

  def test_install_rolls_back_every_home_when_a_later_surface_step_fails
    homes = %w[first second].to_h do |name|
      [name, @temporary.join("transaction-#{name}").tap(&:mkpath)]
    end
    originals = homes.transform_values do |home|
      content = "notify = [\"/usr/bin/true\"]\nmodel = \"#{home.basename}\"\n"
      home.join("config.toml").write(content)
      content
    end
    probe = InstallProbe.new(
      homes: homes, fail_surfaces: true,
      project_root: @project, package_root: PACKAGE, environment: @environment
    )
    probe.configure

    error = assert_raises(TwoHeadWu::AgentObservability::Error) { probe.install }

    assert_includes error.message, "simulated launch surface failure"
    homes.each { |name, home| assert_equal originals.fetch(name), home.join("config.toml").read }
    refute probe.send(:integration_state_file).exist?
  end

  def test_reinstall_restores_and_prunes_deregistered_identity
    old_home = @temporary.join("old-identity").tap(&:mkpath)
    new_home = @temporary.join("new-identity").tap(&:mkpath)
    old_original = "notify = [\"/usr/bin/true\"]\nmodel = \"old\"\n"
    old_home.join("config.toml").write(old_original)
    new_home.join("config.toml").write("model = \"new\"\n")
    probe = InstallProbe.new(
      homes: { "old" => old_home },
      project_root: @project, package_root: PACKAGE, environment: @environment
    )
    probe.configure
    state = { "schema_version" => 1, "homes" => {} }
    probe.send(:install_codex_home!, old_home.to_s, state)
    old_config = old_home.join("config.toml")
    old_config.write(
      old_config.read.sub(
        "/#{TwoHeadWu::AgentObservability::CAPABILITY_VERSION}/", "/0.3.3/"
      )
    )
    probe.homes = { "new" => new_home }

    probe.install

    persisted = JSON.parse(probe.send(:integration_state_file).read)
    assert_equal old_original, old_home.join("config.toml").read
    assert_equal 1, persisted.fetch("homes").length
    assert_includes new_home.join("config.toml").read, TwoHeadWu::AgentObservability::CONFIG_MARKER_BEGIN
  end

  def test_managed_codex_config_refuses_unmanaged_otel_table
    @observability.configure
    home = @temporary.join("identity-conflict")
    home.mkpath
    home.join("config.toml").write("[otel]\nexporter = \"none\"\n")
    error = assert_raises(TwoHeadWu::AgentObservability::Error) do
      @observability.send(:install_codex_home!, home.to_s, { "schema_version" => 1, "homes" => {} })
    end
    assert_includes error.message, "refusing to overwrite"
  end

  def test_uninstall_preflights_all_homes_and_retains_recovery_state_on_drift
    probe = UninstallProbe.new(project_root: @project, package_root: PACKAGE, environment: @environment)
    probe.configure
    state = { "schema_version" => 1, "homes" => {} }
    homes = %w[first second].map { |name| @temporary.join(name) }
    homes.each do |home|
      home.mkpath
      home.join("config.toml").write("model = \"keep\"\n")
      probe.send(:install_codex_home!, home.to_s, state)
    end
    state_file = @project.join("var/large-assets/agent-observability/config/codex-integration.json")
    before_first = homes.first.join("config.toml").read
    drifted = homes.last.join("config.toml").read.sub("notify = ", "# drifted notify = ")
    homes.last.join("config.toml").write(drifted)

    error = assert_raises(TwoHeadWu::AgentObservability::Error) { probe.uninstall }
    assert_includes error.message, "notify drift"
    assert_equal before_first, homes.first.join("config.toml").read
    assert_equal drifted, homes.last.join("config.toml").read
    assert state_file.file?, "recovery state must survive a failed uninstall"
    refute probe.unload_called
  end

  def test_successful_uninstall_restores_all_configs_before_removing_state
    probe = UninstallProbe.new(project_root: @project, package_root: PACKAGE, environment: @environment)
    probe.configure
    home = @temporary.join("restore-success")
    home.mkpath
    original = "notify = [\"/usr/bin/true\"]\nmodel = \"keep\"\n"
    home.join("config.toml").write(original)
    state = { "schema_version" => 1, "homes" => {} }
    probe.send(:install_codex_home!, home.to_s, state)

    result = probe.uninstall
    state_file = @project.join("var/large-assets/agent-observability/config/codex-integration.json")
    assert_equal "uninstalled", result.fetch("result")
    assert_equal true, result.fetch("recovery_state_removed")
    assert_includes home.join("config.toml").read, 'notify = ["/usr/bin/true"]'
    refute_includes home.join("config.toml").read, TwoHeadWu::AgentObservability::CONFIG_MARKER_BEGIN
    refute state_file.exist?
    assert probe.unload_called
  end

  def test_uninstall_rolls_back_config_writes_and_keeps_state_when_unload_fails
    probe = UninstallProbe.new(
      project_root: @project, package_root: PACKAGE, environment: @environment, fail_unload: true
    )
    probe.configure
    homes = %w[first-valid second-valid].map { |name| @temporary.join(name).tap(&:mkpath) }
    state = { "schema_version" => 1, "homes" => {} }
    homes.each do |home|
      home.join("config.toml").write("model = \"keep\"\n")
      probe.send(:install_codex_home!, home.to_s, state)
    end
    installed = homes.to_h { |home| [home, home.join("config.toml").read] }
    state_file = @project.join("var/large-assets/agent-observability/config/codex-integration.json")

    error = assert_raises(TwoHeadWu::AgentObservability::Error) { probe.uninstall }
    assert_includes error.message, "simulated unload failure"
    homes.each { |home| assert_equal installed.fetch(home), home.join("config.toml").read }
    assert state_file.file?, "recovery state must survive a transactional rollback"
  end

  def test_uninstall_refuses_to_claim_success_without_recovery_state
    probe = UninstallProbe.new(project_root: @project, package_root: PACKAGE, environment: @environment)

    error = assert_raises(TwoHeadWu::AgentObservability::Error) { probe.uninstall }
    assert_includes error.message, "not installed"
    refute probe.unload_called
  end

  def test_launch_surface_install_saves_originals_and_restore_plan_is_reversible
    wrapper = Pathname.new(@environment.fetch("HOME")).join(".local/bin/codex")
    wrapper.dirname.mkpath
    wrapper_original = "#!/usr/bin/env bash\nset -euo pipefail\nexec /usr/bin/true \"$@\"\n"
    wrapper.write(wrapper_original)
    wrapper.chmod(0o755)
    settings = Pathname.new(@environment.fetch("HOME")).join("Library/Application Support/Code/User/settings.json")
    settings.dirname.mkpath
    settings.write(JSON.pretty_generate("chatgpt.cliExecutable" => "/previous/codex", "keep" => true) + "\n")
    @observability.send(:install_runtime_bundle!)
    state = { "schema_version" => 1, "homes" => {} }

    @observability.send(:install_launch_surfaces!, state)
    assert_includes wrapper.read, TwoHeadWu::AgentObservability::WRAPPER_MARKER_BEGIN
    assert_includes wrapper.read, "TWO_HEAD_WU_OBSERVABILITY_VENDOR_CODEX"
    assert_includes wrapper.read, @observability.send(:observed_codex_adapter).to_s
    assert_equal wrapper_original, state.dig("launch_surfaces", "codex_wrapper", "previous_content")
    managed_settings = JSON.parse(settings.read)
    assert_equal @observability.send(:observed_codex_adapter).to_s, managed_settings.fetch("chatgpt.cliExecutable")
    assert_equal true, managed_settings.fetch("keep")

    plans = @observability.send(:launch_surface_restore_plans, state)
    assert_equal 2, plans.length
    assert_equal wrapper_original, plans.fetch(0).fetch("restored")
    assert_equal "/previous/codex", JSON.parse(plans.fetch(1).fetch("restored")).fetch("chatgpt.cliExecutable")
  end

  def test_launch_surface_reinstall_migrates_managed_paths_without_losing_originals
    wrapper = Pathname.new(@environment.fetch("HOME")).join(".local/bin/codex")
    wrapper.dirname.mkpath
    wrapper_original = "#!/usr/bin/env bash\nset -euo pipefail\nexec /usr/bin/true \"$@\"\n"
    wrapper.write(wrapper_original)
    wrapper.chmod(0o755)
    settings = Pathname.new(@environment.fetch("HOME")).join("Library/Application Support/Code/User/settings.json")
    settings.dirname.mkpath
    settings.write("{\"keep\":true}\n")
    @observability.send(:install_runtime_bundle!)
    state = { "schema_version" => 1, "homes" => {} }
    @observability.send(:install_launch_surfaces!, state)

    old_version = "0.3.0"
    current_version = TwoHeadWu::AgentObservability::CAPABILITY_VERSION
    old_wrapper = wrapper.read.gsub("/#{current_version}/", "/#{old_version}/")
    wrapper.write(old_wrapper)
    old_settings = JSON.parse(settings.read)
    old_settings["chatgpt.cliExecutable"] = old_settings.fetch("chatgpt.cliExecutable")
                                                       .sub("/#{current_version}/", "/#{old_version}/")
    settings.write(JSON.pretty_generate(old_settings) + "\n")
    state["launch_surfaces"]["codex_wrapper"]["managed_digest"] =
      "sha256:#{Digest::SHA256.hexdigest(old_wrapper)}"
    state["launch_surfaces"]["vscode_settings"]["managed_value"] = old_settings.fetch("chatgpt.cliExecutable")

    @observability.send(:install_launch_surfaces!, state)
    assert_includes wrapper.read, "/#{current_version}/"
    refute_includes wrapper.read, "/#{old_version}/"
    assert_includes JSON.parse(settings.read).fetch("chatgpt.cliExecutable"), "/#{current_version}/"
    assert_equal wrapper_original, state.dig("launch_surfaces", "codex_wrapper", "previous_content")
  end

  def test_launch_surface_install_rolls_back_wrapper_when_settings_write_fails
    probe = SurfaceWriteFailureProbe.new(
      project_root: @project, package_root: PACKAGE, environment: @environment
    )
    wrapper = Pathname.new(@environment.fetch("HOME")).join(".local/bin/codex")
    wrapper.dirname.mkpath
    wrapper_original = "#!/usr/bin/env bash\nset -euo pipefail\nexec /usr/bin/true \"$@\"\n"
    wrapper.write(wrapper_original)
    wrapper.chmod(0o755)
    settings = Pathname.new(@environment.fetch("HOME")).join("Library/Application Support/Code/User/settings.json")
    settings.dirname.mkpath
    settings_original = "{\"keep\":true}\n"
    settings.write(settings_original)
    probe.send(:install_runtime_bundle!)
    probe.enable_settings_failure
    state = { "schema_version" => 1, "homes" => {} }

    error = assert_raises(TwoHeadWu::AgentObservability::Error) do
      probe.send(:install_launch_surfaces!, state)
    end
    assert_includes error.message, "simulated VS Code settings failure"
    assert_equal wrapper_original, wrapper.read
    assert_equal settings_original, settings.read
    refute state.key?("launch_surfaces")
  end

  def test_observed_codex_wrapper_preserves_identity_and_native_resume_arguments
    home = Pathname.new(@environment.fetch("HOME"))
    vendor = home.join(".vscode/extensions/openai.chatgpt-test-darwin-arm64/bin/macos-aarch64/codex")
    vendor.dirname.mkpath
    vendor.write("#!/usr/bin/env bash\nprintf '%s|%s\\n' \"${CODEX_HOME-}\" \"$*\"\n")
    vendor.chmod(0o755)
    identity_home = @temporary.join("identity-home").to_s
    output, error, status = Open3.capture3(
      @environment.merge("CODEX_HOME" => identity_home),
      PACKAGE.join("adapters/codex-observed").to_s,
      "resume", "01a06459-2dd7-7d63-95c7-8acb9d495a22", "--foo"
    )

    assert status.success?, error
    assert_equal "#{identity_home}|resume 01a06459-2dd7-7d63-95c7-8acb9d495a22 --foo\n", output

    vendor.write("#!/usr/bin/ruby\nexit 37\n")
    _output, _error, failed_status = Open3.capture3(
      @environment.merge("CODEX_HOME" => identity_home),
      PACKAGE.join("adapters/codex-observed").to_s,
      "exec", "failure"
    )
    assert_equal 37, failed_status.exitstatus
  end

  def test_observed_codex_wrapper_waits_for_an_active_provider_bootstrap
    home = Pathname.new(Dir.mktmpdir("as", "/tmp"))
    state_root = home.join(".local/state/two-head-wu/agent-observability")
    state_root.mkpath
    fake_package = @temporary.join("supervisor-runtime")
    adapter = fake_package.join("adapters/codex-observed")
    prelaunch = fake_package.join("integrations/codex-prelaunch")
    adapter.dirname.mkpath
    prelaunch.dirname.mkpath
    FileUtils.cp(PACKAGE.join("adapters/codex-observed"), adapter)
    adapter.chmod(0o755)
    marker = @temporary.join("provider-finished")
    prelaunch.write(<<~RUBY)
      #!/usr/bin/ruby
      require "fileutils"
      require "pathname"
      require "socket"
      state = Pathname.new(Dir.home).join(".local/state/two-head-wu/agent-observability")
      FileUtils.mkdir_p(state)
      path = state.join("provider-trigger.sock")
      FileUtils.rm_f(path)
      server = UNIXServer.new(path.to_s)
      socket = server.accept
      abort "missing start signal" unless socket.gets == "start\\n"
      sleep 0.2
      File.write(ENV.fetch("SUPERVISOR_TEST_MARKER"), "finished")
      socket.close
      server.close
      FileUtils.rm_f(path)
    RUBY
    prelaunch.chmod(0o755)
    vendor = home.join(".vscode/extensions/openai.chatgpt-test-darwin-arm64/bin/macos-aarch64/codex")
    vendor.dirname.mkpath
    vendor.write(<<~RUBY)
      #!/usr/bin/ruby
      require "pathname"
      require "socket"
      socket = UNIXSocket.new(Pathname.new(Dir.home).join(".local/state/two-head-wu/agent-observability/provider-trigger.sock").to_s)
      socket.write("start\\n")
      socket.close
      puts ARGV.join(" ")
    RUBY
    vendor.chmod(0o755)

    output, error, status = Open3.capture3(
      @environment.merge("HOME" => home.to_s, "SUPERVISOR_TEST_MARKER" => marker.to_s),
      adapter.to_s,
      "exec", "short"
    )

    assert status.success?, error
    assert_equal "exec short\n", output
    assert_equal "finished", marker.read
  ensure
    FileUtils.rm_rf(home) if home
  end

  def test_observed_codex_wrapper_does_not_block_vendor_when_prelaunch_cannot_spawn
    package = @temporary.join("missing-prelaunch-package")
    adapter = package.join("adapters/codex-observed")
    adapter.dirname.mkpath
    FileUtils.cp(PACKAGE.join("adapters/codex-observed"), adapter)
    adapter.chmod(0o755)
    home = Pathname.new(@environment.fetch("HOME"))
    vendor = home.join(".vscode/extensions/openai.chatgpt-test-darwin-arm64/bin/macos-aarch64/codex")
    vendor.dirname.mkpath
    vendor.write("#!/usr/bin/ruby\nputs ARGV.join(' ')\n")
    vendor.chmod(0o755)
    state_root = home.join(".local/state/two-head-wu/agent-observability")
    state_root.mkpath
    log = state_root.join("provider-trigger.log")
    log.write("existing log\n")

    version_output, version_error, version_status = Open3.capture3(
      @environment, adapter.to_s, "--version"
    )
    assert version_status.success?, version_error
    assert_equal "--version\n", version_output
    assert_empty version_error
    assert_equal "existing log\n", log.read

    output, error, status = Open3.capture3(@environment, adapter.to_s, "exec", "still-runs")

    assert status.success?, error
    assert_equal "exec still-runs\n", output
    assert_includes error, "agent-observability prelaunch unavailable: Errno::ENOENT"
    assert_equal "existing log\n", log.read
  end

  def test_external_project_defaults_provider_data_outside_the_ide_workspace
    instance = TwoHeadWu::AgentObservability.new(
      project_root: "/Volumes/ExampleDisk/two-head-wu",
      package_root: PACKAGE,
      environment: @environment
    )

    assert_equal "/Volumes/ExampleDisk/.ltw-ao", instance.colima_home.to_s
    assert_equal "/Volumes/ExampleDisk/.ltw-ao/data/agent-observability", instance.data_root.to_s
    assert_equal "unix:///Volumes/ExampleDisk/.ltw-ao/ltw-ao/docker.sock",
                 instance.send(:compose_environment).fetch("DOCKER_HOST")
    refute instance.send(:compose_environment).key?("DOCKER_CONTEXT")
    assert_equal "unix:///Volumes/ExampleDisk/.ltw-ao/ltw-ao/docker.sock",
                 instance.runtime_contract.fetch("docker_host")
    assert_equal({ "cpus" => 2, "memory_gib" => 4, "disk_gib" => 100 },
                 instance.runtime_contract.fetch("resource_limits"))
  end

  def test_bounded_runner_terminates_a_stalled_process
    result = TwoHeadWu::AgentObservability::Runner.new.capture(
      {}, RbConfig.ruby, "-e", "sleep 5", timeout_seconds: 0.1
    )

    assert_equal 124, result.status
    assert_includes result.stderr, "timed out"
  end

  def test_configure_refuses_state_outside_registered_large_asset_root
    instance = TwoHeadWu::AgentObservability.new(
      project_root: @project,
      data_root: @temporary.join("elsewhere"),
      package_root: PACKAGE,
      environment: @environment
    )

    error = assert_raises(TwoHeadWu::AgentObservability::Error) { instance.configure }
    assert_includes error.message, "data root must remain"
  end

  def test_configure_refuses_symlinked_runtime_ancestor
    target = @temporary.join("target")
    target.mkpath
    data = @project.join("var/large-assets/agent-observability")
    File.symlink(target, data)

    error = assert_raises(TwoHeadWu::AgentObservability::Error) { @observability.configure }
    assert_includes error.message, "symlink"
  end

  def test_launch_is_project_scoped_trace_only_and_identity_is_not_a_dimension
    home = @temporary.join("identity-home")
    home.mkpath
    probe = LaunchProbe.new(
      home: home,
      project_root: @project,
      package_root: PACKAGE,
      environment: @environment
    )

    assert_equal :captured, probe.launch(identity: "private-alias", codex_arguments: ["exec", "hello"])
    command = probe.captured_command
    override = command.fetch(command.index("-c") + 1)

    assert_equal home.to_s, probe.captured_environment.fetch("CODEX_HOME")
    assert_equal ["-C", @project.to_s], command[1, 2]
    assert_includes override, 'exporter="none"'
    assert_includes override, 'metrics_exporter="none"'
    assert_includes override, 'trace_exporter='
    assert_includes override, '"project.id"="two-head-wu"'
    assert_includes override, '"agent.logical_identity"="two-head-wu-codex"'
    refute_includes override, "private-alias"
    refute @project.join("config.toml").exist?
  end

  def test_launch_rejects_project_remote_and_otel_overrides
    home = @temporary.join("identity-home")
    home.mkpath
    probe = LaunchProbe.new(
      home: home,
      project_root: @project,
      package_root: PACKAGE,
      environment: @environment
    )

    [
      ["-C", "/tmp"],
      ["--cd=/tmp"],
      ["--remote", "ws://example.invalid"],
      ["-c", "otel.exporter=\"none\""],
      ["--config=otel.metrics_exporter=\"statsig\""]
    ].each do |arguments|
      assert_raises(TwoHeadWu::AgentObservability::Error) do
        probe.launch(identity: "private-alias", codex_arguments: arguments)
      end
    end
  end

  def test_query_is_bounded_and_uses_only_allowlisted_templates
    probe = QueryProbe.new(
      project_root: @project,
      package_root: PACKAGE,
      environment: @environment
    )
    result = probe.query(days: 7, group_by: "tool", limit: 25)

    assert_equal "direct-aggregate", result.fetch("classification")
    assert_equal 1, probe.queries.length
    assert_includes probe.queries.first, "INTERVAL 7 DAY"
    assert_includes probe.queries.first, "LIMIT 25"
    assert_includes probe.queries.first, "SpanAttributes['agent.logical_identity'] = 'two-head-wu-codex'"
    assert_includes probe.queries.first, "SpanAttributes['agent.runtime'] = 'codex'"
    assert_raises(TwoHeadWu::AgentObservability::Error) { probe.query(days: 367) }
    assert_raises(TwoHeadWu::AgentObservability::Error) { probe.query(group_by: "sql") }
  end

  def test_project_query_joins_turn_mapping_by_conversation_without_raw_paths
    probe = QueryProbe.new(
      project_root: @project,
      package_root: PACKAGE,
      environment: @environment
    )
    probe.query(days: 7, group_by: "project", limit: 20)
    sql = probe.queries.fetch(0)

    assert_includes sql, "two_head_wu.session_project"
    assert_includes sql, "GROUP BY conversation_id"
    assert_includes sql, "local-unclassified"
    refute_includes sql, @temporary.to_s
  end

  def test_surface_query_uses_only_low_cardinality_codex_dimensions
    probe = QueryProbe.new(project_root: @project, package_root: PACKAGE, environment: @environment)
    result = probe.query(days: 7, group_by: "surface", limit: 20)

    assert_equal "surface", result.fetch("group_by")
    sql = probe.queries.join("\n")
    assert_includes sql, "attrs['originator']"
    assert_includes sql, "attrs['terminal.type']"
    refute_includes sql, "cwd"
  end

  def test_registered_git_and_directory_projects_get_stable_safe_ids
    registry = @project.join("registries/projects_registry.yaml")
    registry.dirname.mkpath
    registry.write(YAML.dump({ "projects" => [{ "id" => "two-head-wu", "name" => "两头乌", "path" => @project.to_s }] }))
    @project.join("nested").mkpath
    assert_equal "two-head-wu", @observability.send(:resolve_local_project, @project.join("nested").to_s).fetch("id")

    git_project = @temporary.join("outside/repository")
    git_project.mkpath
    system("git", "-C", git_project.to_s, "init", "-q")
    git_id = @observability.send(:resolve_local_project, git_project.to_s).fetch("id")
    assert_match(/\Alocal-git-[0-9a-f]{16}\z/, git_id)

    directory = @temporary.join("outside/plain")
    directory.mkpath
    directory_id = @observability.send(:resolve_local_project, directory.to_s).fetch("id")
    assert_match(/\Alocal-dir-[0-9a-f]{16}\z/, directory_id)
    project_map = @project.join("var/large-assets/agent-observability/config/local-project-map.json")
    assert_equal 0o600, project_map.stat.mode & 0o777
  end

  def test_concurrent_project_map_updates_are_serialized_without_lost_entries
    probe = ConcurrentProjectMapProbe.new(
      project_root: @project, package_root: PACKAGE, environment: @environment
    )
    threads = 6.times.map do |index|
      Thread.new do
        id = "local-dir-#{index}"
        probe.send(:persist_local_project, "/safe/#{index}", id, "directory", "project-#{index}")
      end
    end
    threads.each(&:value)
    projects = probe.send(:load_project_map).fetch("projects")

    assert_equal 1, probe.maximum_concurrent_loads
    assert_equal 6, projects.length
    assert_equal 6, projects.keys.grep(/\Alocal-dir-/).length
  end

  def test_notify_uses_only_thread_and_cwd_for_project_mapping
    registry = @project.join("registries/projects_registry.yaml")
    registry.dirname.mkpath
    registry.write(YAML.dump({ "projects" => [{ "id" => "two-head-wu", "name" => "两头乌", "path" => @project.to_s }] }))
    probe = NotifyProbe.new(project_root: @project, package_root: PACKAGE, environment: @environment)
    payload = JSON.generate(
      "thread-id" => "thread-safe-id",
      "cwd" => @project.to_s,
      "input-messages" => ["DO-NOT-STORE"],
      "last-assistant-message" => "DO-NOT-STORE-EITHER"
    )
    result = probe.handle_notify(state_key: "state-key", payload_text: payload)

    assert_equal "two-head-wu", result.fetch("project_id")
    assert_equal "thread-safe-id", probe.mapping.fetch(0)
    assert_equal "two-head-wu", probe.mapping.fetch(1).fetch("id")
    refute_includes JSON.generate(result), "DO-NOT-STORE"
    assert_equal ["state-key", payload], probe.forwarded
  end

  def test_notify_always_forwards_the_previous_dispatcher_when_observation_fails
    probe = NotifyProbe.new(project_root: @project, package_root: PACKAGE, environment: @environment)
    probe.define_singleton_method(:send_project_mapping) do |_conversation_id, _project|
      raise TwoHeadWu::AgentObservability::Error, "simulated observation failure"
    end
    payload = JSON.generate("thread-id" => "thread-safe-id", "cwd" => @project.to_s)

    assert_raises(TwoHeadWu::AgentObservability::Error) do
      probe.handle_notify(state_key: "state-key", payload_text: payload)
    end
    assert_equal ["state-key", payload], probe.forwarded
  end

  def test_notify_uses_verified_cwd_input_without_reading_rollout
    probe = NotifyProbe.new(project_root: @project, package_root: PACKAGE, environment: @environment)
    probe.configure
    home = @temporary.join("session-home")
    home.mkpath
    session_id = "01a06416-bf32-7722-9b71-6a614b279cc0"
    session_cwd = @temporary.join("actual-session-project")
    session_cwd.mkpath
    rollout = home.join("sessions/2026/09/03/rollout-test-#{session_id}.jsonl")
    rollout.dirname.mkpath
    rollout.write("DO-NOT-READ\n")
    rollout.chmod(0o000)

    payload = JSON.generate("thread-id" => session_id, "cwd" => session_cwd.to_s)
    result = probe.handle_notify(state_key: "unknown-state", payload_text: payload)
    expected = "local-dir-#{Digest::SHA256.hexdigest(session_cwd.realpath.to_s)[0, 16]}"
    assert_equal expected, result.fetch("project_id")
    assert_equal expected, probe.mapping.fetch(1).fetch("id")
    assert_equal "notify-cwd", probe.mapping.fetch(1).fetch("attribution")
  ensure
    rollout.chmod(0o600) if rollout&.exist?
  end

  def test_notify_without_absolute_cwd_maps_unclassified_and_records_gap
    probe = NotifyProbe.new(project_root: @project, package_root: PACKAGE, environment: @environment)
    result = probe.handle_notify(
      state_key: "unknown-state",
      payload_text: JSON.generate("thread-id" => "01a06416-bf32-7722-9b71-6a614b279cc0")
    )

    assert_equal "local-unclassified", result.fetch("project_id")
    assert_equal "notify-cwd-unavailable", probe.mapping.fetch(1).fetch("attribution")
    assert_equal "notify-missing-project", probe.send(:all_coverage_gaps).last.fetch("reason")
  end

  def test_project_mapping_uses_collector_compatible_hex_ids
    payload = @observability.send(
      :project_mapping_payload,
      "01a06452-4193-7943-a447-c876ad60d0c0",
      { "id" => "two-head-wu", "kind" => "registered" }
    )
    span = payload.dig("resourceSpans", 0, "scopeSpans", 0, "spans", 0)

    assert_match(/\A[0-9a-f]{32}\z/, span.fetch("traceId"))
    assert_match(/\A[0-9a-f]{16}\z/, span.fetch("spanId"))
    attributes = span.fetch("attributes").to_h { |item| [item.fetch("key"), item.dig("value", "stringValue")] }
    assert_equal "two-head-wu", attributes.fetch("project.id")
    assert_equal "01a06452-4193-7943-a447-c876ad60d0c0", attributes.fetch("conversation.id")
    assert_equal "notify-cwd", attributes.fetch("project.attribution")
  end

  def test_launch_agent_is_socket_activated_and_not_run_at_load
    plist = @observability.send(:launch_agent_plist)

    assert_includes plist, "<key>Sockets</key>"
    assert_includes plist, "<string>127.0.0.1</string>"
    assert_includes plist, "<string>4318</string>"
    assert_match(/<key>RunAtLoad<\/key>\s*<false\/>/, plist)
    assert_match(/<key>KeepAlive<\/key>\s*<false\/>/, plist)
    refute_includes plist, "4319"
  end

  def test_runtime_bundle_keeps_the_provider_bound_to_the_invoked_package
    release_slot = @project.join("var/capability-releases/releases/agent-observability/immutable-release")
    release_slot.dirname.mkpath
    FileUtils.cp_r(PACKAGE.to_s, release_slot.to_s)
    mutable_source = @project.join("capabilities/agent-observability")
    mutable_source.mkpath
    mutable_source.join("capability.yaml").write("version: mutable\n")
    probe = TwoHeadWu::AgentObservability.new(
      project_root: @project, package_root: release_slot, environment: @environment
    )

    probe.send(:install_runtime_bundle!)
    prelaunch = JSON.parse(
      Pathname.new(@environment.fetch("HOME")).join(
        ".local/state/two-head-wu/agent-observability/prelaunch.json"
      ).read
    )

    assert_equal release_slot.to_s, prelaunch.fetch("package_root")
    assert_match(/\Asha256:[0-9a-f]{64}\z/, prelaunch.fetch("package_digest"))
    refute_equal mutable_source.to_s, prelaunch.fetch("package_root")

    runtime_probe = TwoHeadWu::AgentObservability.new(
      project_root: @project,
      package_root: probe.send(:runtime_package_root),
      environment: @environment
    )
    assert_equal release_slot.realpath, runtime_probe.send(:provider_bootstrap_package_root)

    File.open(release_slot.join("deploy/docker-compose.yaml"), "a") { |file| file.puts("# drift") }
    error = assert_raises(TwoHeadWu::AgentObservability::Error) do
      runtime_probe.send(:provider_bootstrap_package_root)
    end
    assert_includes error.message, "content has drifted"
  end

  def test_runtime_notify_refuses_missing_or_system_disk_provider_contract
    runtime_root = @observability.send(:runtime_package_root)
    runtime_root.mkpath
    runtime_probe = TwoHeadWu::AgentObservability.new(
      project_root: @project, package_root: runtime_root, environment: @environment
    )

    missing = assert_raises(TwoHeadWu::AgentObservability::Error) do
      runtime_probe.send(:provider_bootstrap_package_root)
    end
    assert_includes missing.message, "no installed provider package contract"

    contract = runtime_probe.send(:local_state_root).join("prelaunch.json")
    contract.dirname.mkpath
    contract.write(JSON.generate(
      "package_root" => PACKAGE.to_s,
      "package_digest" => @observability.send(:runtime_bundle_digest, PACKAGE)
    ))
    contract.chmod(0o600)
    outside = assert_raises(TwoHeadWu::AgentObservability::Error) do
      runtime_probe.send(:provider_bootstrap_package_root)
    end
    assert_includes outside.message, "outside the registered project"

    contract.write("[]\n")
    malformed = assert_raises(TwoHeadWu::AgentObservability::Error) do
      runtime_probe.send(:provider_bootstrap_package_root)
    end
    assert_includes malformed.message, "contract is invalid"
  end

  def test_runtime_bundle_reinstall_is_idempotent_and_refuses_same_version_drift
    @observability.send(:install_runtime_bundle!)
    runtime_root = @observability.send(:runtime_package_root)
    runtime_root.join("lib/agent_observability.rb").chmod(0o444)

    assert @observability.send(:install_runtime_bundle!)

    drifted = runtime_root.join("capability.yaml")
    drifted.chmod(0o600)
    File.open(drifted, "a") { |file| file.puts("# drift") }
    error = assert_raises(TwoHeadWu::AgentObservability::Error) do
      @observability.send(:install_runtime_bundle!)
    end
    assert_includes error.message, "runtime bundle content drift"
  end

  def test_runtime_bundle_refuses_unexpected_directories_and_symlinks
    @observability.send(:install_runtime_bundle!)
    runtime_root = @observability.send(:runtime_package_root)
    runtime_root.join("unexpected").mkpath

    error = assert_raises(TwoHeadWu::AgentObservability::Error) do
      @observability.send(:install_runtime_bundle!)
    end
    assert_includes error.message, "runtime bundle file set drift"

    runtime_root.join("unexpected").rmdir
    File.symlink(runtime_root.join("capability.yaml"), runtime_root.join("unexpected-link"))
    error = assert_raises(TwoHeadWu::AgentObservability::Error) do
      @observability.send(:install_runtime_bundle!)
    end
    assert_includes error.message, "runtime bundle contains a symlink"

    runtime_root.join("unexpected-link").unlink
    runtime_root.join("capability.yaml").chmod(0o755)
    error = assert_raises(TwoHeadWu::AgentObservability::Error) do
      @observability.send(:install_runtime_bundle!)
    end
    assert_includes error.message, "runtime bundle permission drift"
  end

  def test_lazy_proxy_accepts_bounded_otlp_http_requests
    server, client = Socket.pair(:UNIX, :STREAM, 0)
    body = "safe-body"
    client.write("POST /v1/traces HTTP/1.1\r\nContent-Type: application/x-protobuf\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}")
    proxy = TwoHeadWu::LazyOtlpProxy.new(observability: @observability)
    request_line, headers, parsed_body = proxy.send(:read_http_request, server)

    assert_equal "POST /v1/traces HTTP/1.1", request_line
    assert_equal "application/x-protobuf", headers.fetch("content-type")
    assert_equal body, parsed_body
  ensure
    server.close if server && !server.closed?
    client.close if client && !client.closed?
  end

  def test_lazy_proxy_requires_a_successful_otlp_http_probe_before_forwarding
    requests = []
    [[200, true], [503, false]].each do |status, expected|
      listener = TCPServer.new("127.0.0.1", 0)
      socket = nil
      server = Thread.new do
        socket = listener.accept
        request = +""
        request << socket.readpartial(4096) until request.include?("\r\n\r\n")
        requests << request
        reason = status == 200 ? "OK" : "Service Unavailable"
        socket.write("HTTP/1.1 #{status} #{reason}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        socket.close
      end
      proxy = TwoHeadWu::LazyOtlpProxy.new(
        observability: @observability, backend_port: listener.addr.fetch(1)
      )

      assert_equal expected, proxy.send(:backend_open?)
      Timeout.timeout(1) { server.join }
      listener.close
    ensure
      socket&.close
      listener&.close
      server&.kill
      server&.join
    end

    requests.each do |request|
      assert_match(/\APOST \/v1\/traces HTTP\/1\.1\r\n/, request)
      assert_includes request.downcase, "content-type: application/x-protobuf"
      assert_includes request.downcase, "content-length: 0"
    end
  end

  def test_lazy_proxy_times_out_incomplete_local_connections
    server, client = Socket.pair(:UNIX, :STREAM, 0)
    proxy = TwoHeadWu::LazyOtlpProxy.new(
      observability: @observability, request_read_timeout_seconds: 0.02
    )

    Timeout.timeout(1) { proxy.send(:receive_request, server) }
    response = Timeout.timeout(1) { client.read }

    assert_match(/\AHTTP\/1\.1 400 Bad Request/, response)
    assert_equal "invalid-otlp-request", @observability.send(:all_coverage_gaps).last.fetch("reason")
  ensure
    server.close if server && !server.closed?
    client.close if client && !client.closed?
  end

  def test_lazy_proxy_bounds_pending_local_requests
    proxy = TwoHeadWu::LazyOtlpProxy.new(observability: @observability)
    queue = proxy.instance_variable_get(:@request_queue)
    TwoHeadWu::LazyOtlpProxy::MAX_PENDING_REQUESTS.times { queue << :occupied }
    server, client = Socket.pair(:UNIX, :STREAM, 0)

    refute proxy.send(:enqueue_request, server)
    response = Timeout.timeout(1) { client.read }

    assert_match(/\AHTTP\/1\.1 503 Service Unavailable/, response)
    assert_equal "frontend-overloaded", @observability.send(:all_coverage_gaps).last.fetch("reason")
  ensure
    server.close if server && !server.closed?
    client.close if client && !client.closed?
  end

  def test_lazy_proxy_request_worker_survives_an_unexpected_request_exception
    proxy = TwoHeadWu::LazyOtlpProxy.new(observability: @observability)
    proxy.define_singleton_method(:receive_request) do |socket|
      raise "unexpected request failure" if socket == :bad
    end
    queue = proxy.instance_variable_get(:@request_queue)
    queue << :bad
    queue << :good
    queue << :stop

    Timeout.timeout(1) { proxy.send(:request_worker_loop) }

    assert_equal "proxy-worker-failed", @observability.send(:all_coverage_gaps).last.fetch("reason")
  end

  def test_lazy_proxy_entrypoint_uses_inherited_socket_and_exits_cleanly_on_term
    listener = TCPServer.new("127.0.0.1", 0)
    listener.close_on_exec = false
    port = listener.addr.fetch(1)
    proxy_home = @temporary.join("proxy-process-home").tap(&:mkpath)
    entrypoint = PACKAGE.join("integrations/lazy-otlp-proxy")
    pid = Process.spawn(
      @environment.merge(
        "HOME" => proxy_home.to_s,
        "TWO_HEAD_WU_OBSERVABILITY_LISTEN_FD" => listener.fileno.to_s
      ),
      entrypoint.to_s,
      "--project-root", @project.to_s,
      "--data-root", @project.join("var/large-assets/agent-observability").to_s,
      listener.fileno => listener.fileno,
      out: File::NULL,
      err: File::NULL
    )
    client = nil
    Timeout.timeout(2) do
      begin
        client = TCPSocket.new("127.0.0.1", port)
      rescue Errno::ECONNREFUSED
        sleep 0.01
        retry
      end
    end
    client.write("GET / HTTP/1.1\r\nContent-Length: 0\r\n\r\n")
    response = Timeout.timeout(2) { client.read }
    assert_match(/\AHTTP\/1\.1 404 Not Found/, response)

    Process.kill("TERM", pid)
    Timeout.timeout(3) { Process.wait(pid) }
    assert_predicate $?, :success?
  ensure
    client&.close
    listener&.close
    begin
      Process.kill("KILL", pid) if pid && Process.waitpid(pid, Process::WNOHANG).nil?
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end
  end

  def test_lazy_proxy_keeps_trace_in_memory_until_backend_becomes_ready
    proxy = WaitingProxy.new(observability: @observability)
    item = { "body" => "trace", "content_type" => "application/x-protobuf", "content_encoding" => nil, "phase" => nil }
    proxy.send(:enqueue, item)
    worker = Thread.new { proxy.send(:worker_loop) }
    sleep 0.05
    assert proxy.forwarded.empty?, "trace must not be dropped while a long Codex turn is still running"
    assert_equal 1, proxy.provider_start_count, "first telemetry must request provider startup before notify"
    proxy.release_backend
    assert_equal item, Timeout.timeout(1) { proxy.forwarded.pop }
    proxy.instance_variable_get(:@queue) << :stop
    worker.join(1)
    refute worker.alive?
  end

  def test_production_proxy_has_no_fixed_provider_readiness_deadline
    proxy = NeverReadyProxy.new(observability: @observability, provider_poll_seconds: 0.005)
    item = { "body" => "trace", "content_type" => "application/x-protobuf", "content_encoding" => nil,
             "phase" => nil }
    proxy.send(:enqueue, item)
    worker = Thread.new { proxy.send(:worker_loop) }

    sleep 0.03
    assert worker.alive?, "production trace must remain queued without a fixed readiness deadline"
    assert_equal item.fetch("body").bytesize, proxy.instance_variable_get(:@queued_bytes)
    proxy.instance_variable_set(:@stopping, true)
    proxy.instance_variable_get(:@queue) << :stop
    worker.join(1)
    refute worker.alive?
    assert_equal 0, proxy.instance_variable_get(:@queued_bytes)
  ensure
    proxy&.instance_variable_set(:@stopping, true)
    proxy&.instance_variable_get(:@queue)&.push(:stop)
    worker&.join(1)
  end

  def test_lazy_proxy_queue_is_bounded_and_failure_does_not_block_codex
    proxy = TwoHeadWu::LazyOtlpProxy.new(observability: @observability)
    proxy.instance_variable_set(:@queued_bytes, TwoHeadWu::LazyOtlpProxy::MAX_QUEUED_BYTES)
    server, client = Socket.pair(:UNIX, :STREAM, 0)
    client.write("POST /v1/traces HTTP/1.1\r\nContent-Type: application/x-protobuf\r\nContent-Length: 1\r\n\r\nx")

    Timeout.timeout(1) { proxy.send(:receive_request, server) }
    response = Timeout.timeout(1) { client.read }
    assert_match(/\AHTTP\/1\.1 503 Service Unavailable/, response)
    gap = @observability.send(:all_coverage_gaps).last
    assert_equal "queue-full", gap.fetch("reason")
    assert_equal "commissioning", gap.fetch("phase")
    assert_equal 1, gap.fetch("bytes")
  ensure
    server.close if server && !server.closed?
    client.close if client && !client.closed?
  end

  def test_lazy_proxy_records_provider_failure_after_bounded_readiness_wait
    proxy = NeverReadyProxy.new(
      observability: @observability,
      provider_ready_timeout_seconds: 0.02,
      provider_poll_seconds: 0.005
    )
    item = { "body" => "trace", "content_type" => "application/x-protobuf", "content_encoding" => nil,
             "phase" => "commissioning" }
    proxy.send(:enqueue, item)
    proxy.instance_variable_get(:@queue) << :stop

    Timeout.timeout(1) { proxy.send(:worker_loop) }
    gap = @observability.send(:all_coverage_gaps).last
    assert_equal "provider-start-failed", gap.fetch("reason")
    assert_equal 0, proxy.instance_variable_get(:@queued_bytes)
  end

  def test_recent_gap_limit_is_applied_after_phase_filtering
    @observability.record_coverage_gap("frontend-unavailable", phase: "production")
    101.times do
      @observability.record_coverage_gap("frontend-unavailable", phase: "commissioning")
    end

    production = @observability.send(:recent_coverage_gaps, phase: "production")

    assert_equal 1, production.length
    assert_equal "production", production.first.fetch("phase")
  end

  def test_coverage_ignores_valid_json_scalars_without_crashing
    gap_file = @observability.send(:coverage_gap_file)
    gap_file.dirname.mkpath
    gap_file.write("null\n[]\n42\n")

    assert_empty @observability.send(:all_coverage_gaps)
  end

  def test_launchd_proxy_uses_only_local_broker_signal_for_provider_start
    observability = ProxySignalProbe.new
    proxy = TwoHeadWu::LazyOtlpProxy.new(observability: observability)

    assert_equal true, proxy.send(:request_provider_start)
    assert_equal true, proxy.send(:request_provider_start)
    assert_equal 2, observability.signal_count
  end

  def test_worker_records_failure_and_continues_with_the_next_trace
    proxy = ResilientProxy.new(observability: @observability)
    bad = { "body" => "bad", "content_type" => "application/x-protobuf", "content_encoding" => nil,
            "phase" => "commissioning" }
    good = bad.merge("body" => "good")
    proxy.send(:enqueue, bad)
    proxy.send(:enqueue, good)
    proxy.instance_variable_get(:@queue) << :stop

    Timeout.timeout(1) { proxy.send(:worker_loop) }

    assert_equal good, proxy.forwarded.pop
    assert_equal "proxy-worker-failed", @observability.send(:all_coverage_gaps).last.fetch("reason")
    assert_equal 0, proxy.instance_variable_get(:@queued_bytes)
  end

  def test_provider_trigger_broker_survives_liveness_and_invalid_connections
    broker = PACKAGE.join("integrations/provider-trigger-broker")
    broker_home = Pathname.new(Dir.mktmpdir("ao-broker", "/tmp"))
    socket_path = broker_home.join(
      ".local/state/two-head-wu/agent-observability/provider-trigger.sock"
    )
    pid = Process.spawn(
      @environment.merge("HOME" => broker_home.to_s),
      broker.to_s,
      "--project-root", @project.to_s,
      "--data-root", @project.join("var/large-assets/agent-observability").to_s,
      "--package-root", PACKAGE.to_s,
      out: File::NULL,
      err: File::NULL
    )
    Timeout.timeout(2) { sleep 0.01 until socket_path.socket? }
    sleep 1.1
    assert Process.kill(0, pid)
    socket = UNIXSocket.new(socket_path.to_s)
    socket.write("ignore\n")
    socket.close
    sleep 0.1
    assert Process.kill(0, pid)

    socket = UNIXSocket.new(socket_path.to_s)
    socket.write("ping\n")
    assert_equal "ok\n", Timeout.timeout(1) { socket.gets }
    socket.close
    assert Process.kill(0, pid)

    idle = UNIXSocket.new(socket_path.to_s)
    sleep 1.1
    idle.close
    assert Process.kill(0, pid)
    refute_includes broker.read, "Timeout.timeout"
  ensure
    begin
      Process.kill("TERM", pid) if pid && Process.waitpid(pid, Process::WNOHANG).nil?
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end
    FileUtils.rm_rf(broker_home) if broker_home
  end

  def test_provider_trigger_broker_executes_bootstrap_after_start_signal
    broker_home = Pathname.new(Dir.mktmpdir("ab", "/tmp"))
    socket_path = broker_home.join(
      ".local/state/two-head-wu/agent-observability/provider-trigger.sock"
    )
    runtime = broker_home.join("runtime")
    broker = runtime.join("integrations/provider-trigger-broker")
    fake_bootstrap = runtime.join("integrations/provider-bootstrap")
    fake_bootstrap.dirname.mkpath
    FileUtils.cp(PACKAGE.join("integrations/provider-trigger-broker"), broker)
    broker.chmod(0o755)
    external_package = broker_home.join("external-release")
    external_package.mkpath
    marker = broker_home.join("bootstrap-arguments")
    fake_bootstrap.write(<<~RUBY)
      #!/usr/bin/ruby
      File.write(ENV.fetch("BROKER_TEST_MARKER"), ARGV.join("\n"))
    RUBY
    fake_bootstrap.chmod(0o755)
    pid = Process.spawn(
      @environment.merge("HOME" => broker_home.to_s, "BROKER_TEST_MARKER" => marker.to_s),
      broker.to_s,
      "--project-root", @project.to_s,
      "--data-root", @project.join("var/large-assets/agent-observability").to_s,
      "--package-root", external_package.to_s,
      out: File::NULL,
      err: File::NULL
    )
    Timeout.timeout(2) { sleep 0.01 until socket_path.socket? }
    socket = UNIXSocket.new(socket_path.to_s)
    socket.write("start\n")
    socket.close
    Timeout.timeout(2) { Process.wait(pid) }

    assert marker.file?
    arguments = marker.read.lines(chomp: true)
    assert_equal @project.to_s, arguments.fetch(arguments.index("--project-root") + 1)
    assert_equal external_package.to_s, arguments.fetch(arguments.index("--package-root") + 1)
  ensure
    begin
      Process.kill("TERM", pid) if pid && Process.waitpid(pid, Process::WNOHANG).nil?
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end
    socket&.close
    FileUtils.rm_rf(broker_home) if broker_home
  end

  def test_notify_provider_spawn_failure_degrades_to_coverage_gap
    probe = BootstrapFailureProbe.new(
      project_root: @project, package_root: PACKAGE, environment: @environment
    )

    refute probe.send(:request_provider_start)
    gap = probe.send(:all_coverage_gaps).last
    assert_equal "provider-start-failed", gap.fetch("reason")
    assert_equal "commissioning", gap.fetch("phase")
  end

  def test_notify_provider_fallback_appends_to_a_private_log
    runtime = @temporary.join("fallback-runtime")
    bootstrap = runtime.join("integrations/provider-bootstrap")
    bootstrap.dirname.mkpath
    bootstrap.write("#!/usr/bin/ruby\nputs 'new bootstrap evidence'\n")
    bootstrap.chmod(0o755)
    probe = TwoHeadWu::AgentObservability.new(
      project_root: @project, package_root: PACKAGE, environment: @environment
    )
    probe.define_singleton_method(:otlp_backend_ready?) { |_port = 4319| false }
    probe.define_singleton_method(:signal_provider_trigger) { false }
    probe.define_singleton_method(:runtime_package_root) { runtime }
    probe.define_singleton_method(:provider_bootstrap_package_root) { PACKAGE }
    log = probe.send(:provider_bootstrap_log)
    log.dirname.mkpath
    log.write("old bootstrap evidence\n")

    assert probe.send(:request_provider_start)
    Timeout.timeout(2) { sleep 0.01 until log.read.include?("new bootstrap evidence") }

    assert_equal "old bootstrap evidence\nnew bootstrap evidence\n", log.read
    assert_equal 0o600, log.stat.mode & 0o777
  end

  def test_commissioning_gaps_are_preserved_but_do_not_reduce_production_coverage
    @observability.configure
    gap_file = @observability.send(:coverage_gap_file)
    gap_file.dirname.mkpath
    pre_activation = {
      "timestamp" => (Time.now.utc - 3600).iso8601,
      "reason" => "queue-full",
      "phase" => "production",
      "project_id" => "local-unclassified"
    }
    gap_file.write(JSON.generate(pre_activation) + "\n")
    state_file = @observability.send(:integration_state_file)
    state_file.write(JSON.generate(
      "schema_version" => 1,
      "homes" => {},
      "verification" => { "state" => "active", "verified_at" => Time.now.utc.iso8601 }
    ))
    state_file.chmod(0o600)
    @observability.record_coverage_gap("backend-forward-failed", phase: "production")
    commissioning = @observability.send(:recent_coverage_gaps, phase: "commissioning")
    production = @observability.send(:recent_coverage_gaps, phase: "production")

    assert_equal ["queue-full"], commissioning.map { |row| row.fetch("reason") }
    assert_equal "production", commissioning.first.fetch("recorded_phase")
    assert_equal "pre-verification-activation", commissioning.first.fetch("classification")
    assert_equal ["backend-forward-failed"], production.map { |row| row.fetch("reason") }
    assert_equal 2, @observability.send(:all_coverage_gaps).length
  end

  def test_reverification_never_moves_the_first_production_activation_boundary
    probe = VerificationProbe.new(project_root: @project, package_root: PACKAGE, environment: @environment)
    probe.configure
    activated_at = (Time.now.utc - 3600).iso8601
    state_file = probe.send(:integration_state_file)
    state_file.write(JSON.generate(
      "schema_version" => 1,
      "homes" => {},
      "verification" => { "state" => "active", "verified_at" => activated_at }
    ))
    state_file.chmod(0o600)

    probe.verify(project_id: "two-head-wu", conversation_id: "01a06568-2084-7271-bb7a-1220fad40625")
    verification = JSON.parse(state_file.read).fetch("verification")
    marker = JSON.parse(probe.send(:verification_marker).read)

    assert_equal activated_at, verification.fetch("activated_at")
    assert_equal activated_at, marker.fetch("activated_at")
    assert_operator Time.parse(verification.fetch("verified_at")), :>=, Time.parse(activated_at)
  end

  def test_uninstall_and_reinstall_preserve_first_production_activation_boundary
    probe = UninstallProbe.new(project_root: @project, package_root: PACKAGE, environment: @environment)
    probe.configure
    home = @temporary.join("verification-history-home")
    home.mkpath
    home.join("config.toml").write("model = \"keep\"\n")
    state = { "schema_version" => 1, "homes" => {} }
    probe.send(:install_codex_home!, home.to_s, state)
    activated_at = (Time.now.utc - 3600).iso8601
    state_file = probe.send(:integration_state_file)
    persisted = JSON.parse(state_file.read)
    persisted["verification"] = {
      "state" => "active", "activated_at" => activated_at, "verified_at" => activated_at
    }
    probe.send(:atomic_write, state_file, JSON.pretty_generate(persisted) + "\n", mode: 0o600)
    probe.send(:write_verification_marker)
    marker = probe.send(:verification_marker)

    probe.uninstall
    assert marker.file?, "verification history must survive a reversible integration uninstall"
    refute probe.send(:integration_verified?), "an uninstalled integration is not actively verified"

    verifying = VerificationProbe.new(project_root: @project, package_root: PACKAGE, environment: @environment)
    empty_state = { "schema_version" => 1, "homes" => {} }
    verifying.send(:atomic_write, state_file, JSON.pretty_generate(empty_state) + "\n", mode: 0o600)
    verifying.verify(project_id: "two-head-wu", conversation_id: "01a06568-2084-7271-bb7a-1220fad40625")
    verification = JSON.parse(state_file.read).fetch("verification")
    assert_equal activated_at, verification.fetch("activated_at")
  end

  def test_launchd_gap_phase_uses_only_local_install_and_verification_markers
    launch_agent = @observability.send(:launch_agent_file)
    launch_agent.dirname.mkpath
    launch_agent.write(@observability.send(:launch_agent_plist))
    verification = @observability.send(:verification_marker)
    verification.dirname.mkpath
    verification.write(JSON.generate("state" => "active", "activated_at" => Time.now.utc.iso8601))
    state_file = @observability.send(:integration_state_file)
    state_file.dirname.mkpath
    state_file.write("external state must not be read\n")
    state_file.chmod(0o000)

    assert @observability.send(:integration_verified?)
    @observability.record_coverage_gap("proxy-worker-failed")
    assert_equal "production", @observability.send(:coverage_gap_file).read.lines.last.then { |line| JSON.parse(line) }.fetch("phase")
  ensure
    state_file.chmod(0o600) if state_file&.exist?
  end

  def test_large_proxy_log_is_archived_instead_of_truncated
    log = @observability.send(:proxy_stderr_file)
    log.dirname.mkpath
    log.write("x" * (1_048_576 + 1))

    @observability.send(:prepare_proxy_stderr_file!)
    archives = Dir.glob("#{log}.*.archive")

    assert_equal 0, log.size
    assert_equal 1, archives.length
    assert_equal 1_048_577, File.size(archives.first)
    assert_equal 0o600, File.stat(archives.first).mode & 0o777
  end

  def test_model_query_joins_model_and_token_events_by_trace
    probe = QueryProbe.new(
      project_root: @project,
      package_root: PACKAGE,
      environment: @environment
    )
    probe.query(days: 7, group_by: "model", limit: 20)
    sql = probe.queries.fetch(0)

    assert_includes sql, "WITH per_trace AS"
    assert_includes sql, "GROUP BY TraceId"
    assert_includes sql, "WHERE trace_observations > 0"
  end

  def test_capability_query_counts_invocations_without_claiming_token_allocation
    probe = QueryProbe.new(
      project_root: @project,
      package_root: PACKAGE,
      environment: @environment
    )
    result = probe.query(days: 7, group_by: "capability", limit: 20)
    sql = probe.queries.fetch(0)

    assert_includes sql, "two_head_wu.capability_invocation"
    assert_includes sql, "attrs['capability.id']"
    refute_includes sql, "codex.usage.total_tokens"
    assert_includes result.fetch("not_claimed"), "Skill use"
  end

  def test_capability_query_excludes_unregistered_test_or_spoofed_ids
    registry = @project.join("catalog/packages_registry.yaml")
    registry.dirname.mkpath
    registry.write(YAML.dump(
      "packages" => [{ "id" => "agent-observability" }, { "id" => "research-library" }]
    ))
    probe = QueryProbe.new(project_root: @project, package_root: PACKAGE, environment: @environment)
    probe.define_singleton_method(:clickhouse_query) do |_sql|
      [
        { "capability" => "agent-observability", "calls" => "1" },
        { "capability" => "demo", "calls" => "10" }
      ]
    end

    facts = probe.query(days: 7, group_by: "capability", limit: 20).fetch("facts")
    assert_equal ["agent-observability"], facts.map { |row| row.fetch("capability") }
  end

  def test_privacy_query_checks_scope_status_and_forbidden_keys
    probe = QueryProbe.new(
      project_root: @project,
      package_root: PACKAGE,
      environment: @environment
    )
    probe.define_singleton_method(:clickhouse_query) do |sql|
      queries << sql
      [{
        "unscoped_rows" => "0",
        "nonempty_status_message_rows" => "0",
        "forbidden_attribute_rows" => "0"
      }]
    end
    result = probe.send(:database_privacy_counts)
    sql = probe.queries.fetch(0)

    assert_equal true, result.fetch("passed")
    assert_includes sql, "unscoped_rows"
    assert_includes sql, "nonempty_status_message_rows"
    assert_includes sql, "forbidden_attribute_rows"
    assert_includes sql, "SpanAttributes['project.id']"
  end

  def test_database_health_queries_reject_missing_or_invalid_counts
    probe = TwoHeadWu::AgentObservability.new(
      project_root: @project, package_root: PACKAGE, environment: @environment
    )
    probe.define_singleton_method(:clickhouse_query) { |_sql| [{ "traces" => "1" }] }

    assert_equal({ "traces" => nil, "logs" => nil }, probe.send(:database_counts))

    probe.define_singleton_method(:clickhouse_query) do |_sql|
      [{
        "unscoped_rows" => "0",
        "nonempty_status_message_rows" => "not-a-count",
        "forbidden_attribute_rows" => "0"
      }]
    end
    result = probe.send(:database_privacy_counts)
    assert_equal false, result.fetch("passed")
    assert_nil result.fetch("nonempty_status_message_rows")
  end

  def test_clickhouse_non_object_json_is_reported_as_unhealthy_instead_of_crashing
    probe = TwoHeadWu::AgentObservability.new(
      project_root: @project, package_root: PACKAGE, environment: @environment
    )
    probe.define_singleton_method(:provider_environment) do
      { "OPENLIT_DB_USER" => "u", "OPENLIT_DB_PASSWORD" => "p", "OPENLIT_DB_NAME" => "d" }
    end
    probe.define_singleton_method(:compose_command) { ["compose"] }
    probe.define_singleton_method(:run!) do |_command, environment:, timeout_seconds:|
      raise "missing environment" unless environment
      raise "missing timeout" unless timeout_seconds
      TwoHeadWu::AgentObservability::Result.new(stdout: "[]\n", stderr: "", status: 0)
    end

    error = assert_raises(TwoHeadWu::AgentObservability::Error) do
      probe.send(:clickhouse_query, "SELECT 1")
    end
    assert_includes error.message, "invalid response shape"
    assert_equal({ "traces" => nil, "logs" => nil }, probe.send(:database_counts))
  end

  def test_provider_files_pin_versions_bind_loopback_and_have_trace_only_pipeline
    compose = PACKAGE.join("deploy/docker-compose.yaml").read
    collector = PACKAGE.join("deploy/otel-collector-config.yaml").read
    implementation = PACKAGE.join("lib/agent_observability.rb").read

    assert_includes compose, TwoHeadWu::AgentObservability::OPENLIT_IMAGE
    assert_includes compose, TwoHeadWu::AgentObservability::CLICKHOUSE_IMAGE
    assert_includes compose, "127.0.0.1:3000:3000"
    assert_includes compose, "127.0.0.1:4319:4318"
    assert_includes compose, 'entrypoint: ["/app/opamp/otelcontribcol"]'
    parsed_compose = YAML.safe_load(compose)
    refute parsed_compose.dig("services", "clickhouse").key?("ports")
    host_ports = parsed_compose.fetch("services").values.flat_map { |service| Array(service["ports"]) }
    assert host_ports.all? { |port| port.start_with?("127.0.0.1:") }
    refute_includes implementation, "DOCKER_CONTEXT"
    refute_includes implementation, '"--context"'
    assert_includes collector, "filter/owner_local_codex"
    assert_includes collector, "transform/privacy"
    assert_includes collector, 'attributes["project.id"]'
    refute_includes collector, 'gen_ai\\..*'
    refute_includes collector, 'codex\\..*'
    refute_match(/\|slug\|/, collector)
    pipelines = YAML.safe_load(collector).dig("service", "pipelines")
    assert_equal ["traces"], pipelines.keys
    refute_includes collector, "prompt ="
    refute_includes collector, "tool.output"
  end

  def test_upstream_initialization_asset_is_exactly_pinned
    digest = Digest::SHA256.file(PACKAGE.join("deploy/clickhouse-init.sh")).hexdigest
    assert_equal "c362c4aa78015e3634839859866b6d224b90a6bb9ebc01043bd146f6051c8dc1", digest
  end

  def test_compose_ndjson_is_supported_on_system_ruby
    records = @observability.send(
      :parse_json_records,
      "{\"Service\":\"clickhouse\",\"Health\":\"healthy\"}\n" \
      "{\"Service\":\"openlit\",\"Health\":\"starting\"}\n"
    )
    assert_equal %w[clickhouse openlit], records.map { |item| item.fetch("Service") }
  end
end
