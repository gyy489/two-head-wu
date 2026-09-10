# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "pathname"
require "tmpdir"
require "yaml"

require_relative "../lib/capability_release_manager"

class CapabilityReleaseManagerTest < Minitest::Test
  PROJECT_ROOT = Pathname.new(__dir__).join("../../..").realpath
  ADAPTER = PROJECT_ROOT.join("capabilities/capability-release-management/adapters/capability-release-manager")
  GIT_ISOLATION_ENV = {
    "GIT_DIR" => nil,
    "GIT_WORK_TREE" => nil,
    "GIT_COMMON_DIR" => nil,
    "GIT_INDEX_FILE" => nil,
  }.freeze

  def setup
    @temporary = Pathname.new(Dir.mktmpdir("capability-release-manager"))
    @root = @temporary.join("project")
    @state = @temporary.join("state")
    %w[catalog/resources registries capabilities].each { |item| @root.join(item).mkpath }
    write_yaml("catalog/resources/infrastructure.yaml", { "resources" => [] })
    write_yaml("catalog/packages_registry.yaml", {
      "packages" => [{
        "id" => "demo", "version" => "1.0.0", "status" => "active",
        "path" => "capabilities/demo-v1", "manifest" => "capabilities/demo-v1/capability.yaml"
      }]
    })
    write_yaml("registries/projects_registry.yaml", {
      "projects" => %w[pinned compatible latest].map do |id|
        {
          "id" => id,
          "allowed_runtimes" => %w[codex claude-code],
          "capabilities" => { "packages" => ["demo"] }
        }
      end
    })
    @permission_digest = TwoHeadWu::CapabilityReleaseManager.permission_digest(permission_contract)
    @releases = [
      create_release("1.0.0", "one"),
      create_release("1.1.0", "one-one"),
      create_release("2.0.0", "two"),
      create_release("3.0.0-pre.1", "prerelease")
    ]
    write_release_catalog
    write_binding_catalog
  end

  def teardown
    FileUtils.rm_rf(@temporary)
  end

  def test_policy_resolution_is_deterministic
    manager = manager()

    assert_equal "1.0.0", manager.resolve(project_id: "pinned").first.fetch("version")
    assert_equal "1.1.0", manager.resolve(project_id: "compatible").first.fetch("version")
    assert_equal "2.0.0", manager.resolve(project_id: "latest").first.fetch("version")
  end

  def test_dry_run_writes_nothing_and_automatic_skips_pinned
    result = manager.update(project_id: "compatible", automatic: true, apply: false)

    assert_equal true, result.fetch("dry_run")
    assert_equal "1.1.0", result.fetch("plans").first.fetch("target")
    refute @state.exist?
    assert_empty manager.update(project_id: "pinned", automatic: true, apply: false).fetch("plans")
  end

  def test_install_activate_stable_invoke_and_rollback
    manager.update(project_id: "compatible", version: "1.0.0", apply: true)
    assert_equal "1.0.0", manager.status(project_id: "compatible").first.fetch("active")
    manager.update(project_id: "compatible", apply: true)
    assert_equal "1.1.0", manager.status(project_id: "compatible").first.fetch("active")

    stdout, stderr, status = run_cli(
      "invoke", "demo", "--project", "compatible", "--runtime", "codex",
      "--interface", "demo.echo.v1", "--", "hello"
    )
    assert status.success?, stderr
    assert_equal "demo-one-one:hello\n", stdout

    manager.update(project_id: "pinned", apply: true)
    result = manager.rollback(project_id: "compatible", capability_id: "demo", version: "1.0.0", apply: true)
    assert_equal true, result.fetch("rolled_back")
    assert_equal "1.0.0", manager.status(project_id: "compatible").first.fetch("active")
  end

  def test_explicit_update_version_must_remain_compatible
    error = assert_raises(TwoHeadWu::CapabilityReleaseManager::Error) do
      manager.update(project_id: "pinned", version: "2.0.0", apply: true)
    end
    assert_includes error.message, "no compatible release"
    assert_raises(TwoHeadWu::CapabilityReleaseManager::Error) do
      manager.update(project_id: "compatible", version: "1.0.0", automatic: true)
    end
  end

  def test_failed_smoke_test_preserves_active_release
    manager.update(project_id: "compatible", apply: true)
    before = File.readlink(@state.join("projects/compatible/active/demo"))
    @releases << create_release("1.2.0", "broken", smoke_success: false)
    write_release_catalog

    error = assert_raises(TwoHeadWu::CapabilityReleaseManager::Error) do
      manager().update(project_id: "compatible", apply: true)
    end
    assert_includes error.message, "release smoke test failed"
    assert_equal before, File.readlink(@state.join("projects/compatible/active/demo"))
    assert_equal "1.1.0", manager().status(project_id: "compatible").first.fetch("active")
  end

  def test_digest_failure_preserves_active_release
    manager.update(project_id: "compatible", apply: true)
    before = File.readlink(@state.join("projects/compatible/active/demo"))
    bad = create_release("1.3.0", "tampered")
    bad.fetch("source")["digest"] = "sha256:#{'0' * 64}"
    @releases << bad
    write_release_catalog

    error = assert_raises(TwoHeadWu::CapabilityReleaseManager::Error) do
      manager().update(project_id: "compatible", apply: true)
    end
    assert_includes error.message, "digest mismatch"
    assert_equal before, File.readlink(@state.join("projects/compatible/active/demo"))
  end

  def test_concurrent_updates_leave_one_valid_active_pointer
    commands = 2.times.map do
      [
        ADAPTER.to_s, "update", "--project", "compatible", "--apply", "--json",
        "--root", @root.to_s, "--state-root", @state.to_s
      ]
    end
    results = commands.map { |command| Thread.new { Open3.capture3(*command) } }.map(&:value)
    results.each { |_out, error, status| assert status.success?, error }

    pointer = @state.join("projects/compatible/active/demo")
    assert pointer.symlink?
    assert_equal "1.1.0", YAML.safe_load(pointer.realpath.join(".release.yaml").read).fetch("version")
    assert_equal 1, @state.join("releases/demo").children.count { |item| item.directory? }
  end

  def test_binding_cannot_expand_legacy_authorization
    data = YAML.safe_load(@root.join("catalog/project_capability_bindings.yaml").read)
    data.fetch("bindings").first["capability"] = "unknown"
    write_yaml("catalog/project_capability_bindings.yaml", data)

    error = assert_raises(TwoHeadWu::CapabilityReleaseManager::Error) { manager() }
    assert_includes error.message, "unknown Capability"
  end

  def test_invalid_semantic_version_is_rejected
    @releases << create_release("01.2.3", "invalid")
    write_release_catalog

    error = assert_raises(TwoHeadWu::CapabilityReleaseManager::Error) { manager() }
    assert_includes error.message, "not Semantic Versioning"
  end

  def test_smoke_test_timeout_preserves_inactive_state
    release = create_release("1.2.0", "slow")
    release["smoke_tests"] = [["ruby", "-e", "sleep 5"]]
    @releases << release
    write_release_catalog

    error = assert_raises(TwoHeadWu::CapabilityReleaseManager::Error) do
      manager(smoke_timeout_seconds: 0.05).update(project_id: "compatible", apply: true)
    end
    assert_includes error.message, "smoke test timed out"
    refute @state.join("projects/compatible/active/demo").exist?
  end

  def test_invoke_enforces_runtime_and_interface_binding
    manager.update(project_id: "pinned", apply: true)

    _out, error, status = run_cli(
      "invoke", "demo", "--project", "pinned", "--runtime", "openclaw",
      "--interface", "demo.echo.v1"
    )
    refute status.success?
    assert_includes error, "runtime is not allowed"

    _out, error, status = run_cli(
      "invoke", "demo", "--project", "pinned", "--runtime", "codex",
      "--interface", "demo.admin.v1"
    )
    refute status.success?
    assert_includes error, "interface is not allowed"
  end

  def test_invoke_rejects_tampered_installed_slot
    manager.update(project_id: "pinned", apply: true)
    adapter = @state.join("projects/pinned/active/demo").realpath.join("adapters/echo")
    adapter.chmod(0o755)
    File.open(adapter, "a", encoding: "UTF-8") { |file| file.puts("# tampered") }

    _out, error, status = run_cli(
      "invoke", "demo", "--project", "pinned", "--runtime", "codex",
      "--interface", "demo.echo.v1"
    )
    refute status.success?
    assert_includes error, "content digest mismatch"

    update_error = assert_raises(TwoHeadWu::CapabilityReleaseManager::Error) do
      manager.update(project_id: "pinned", apply: true)
    end
    assert_includes update_error.message, "content digest mismatch"
  end

  def test_git_tree_release_is_verified_and_activated
    release = @releases.find { |item| item.fetch("version") == "1.0.0" }
    source_path = release.dig("source", "path")
    run_git("init")
    run_git("add", source_path)
    run_git("-c", "user.name=Two Head Wu Test", "-c", "user.email=test@two-head-wu.invalid",
            "commit", "-m", "fixture release")
    revision = run_git("rev-parse", "HEAD").strip
    tree = run_git("rev-parse", "#{revision}:#{source_path}").strip
    release["source"] = release.fetch("source").merge(
      "kind" => "git-tree", "revision" => revision, "tree" => tree
    )
    write_release_catalog

    with_environment(
      "GIT_DIR" => @temporary.join("outer-poison.git").to_s,
      "GIT_WORK_TREE" => PROJECT_ROOT.to_s,
      "GIT_COMMON_DIR" => @temporary.join("outer-common.git").to_s,
      "GIT_INDEX_FILE" => @temporary.join("outer-index").to_s
    ) { manager.update(project_id: "pinned", apply: true) }
    assert_equal "1.0.0", manager.status(project_id: "pinned").first.fetch("active")
  end

  def test_runtime_caches_do_not_change_source_digest_or_enter_release_slot
    release = @releases.find { |item| item.fetch("version") == "1.0.0" }
    source = @root.join(release.dig("source", "path"))
    expected = release.dig("source", "digest")
    cache = source.join("lib/__pycache__")
    cache.mkpath
    cache.join("module.cpython-311.pyc").binwrite("runtime-cache")
    source.join(".DS_Store").binwrite("finder-cache")
    assert_equal expected, TwoHeadWu::CapabilityReleaseManager.directory_digest(source)

    real_source = source.join("lib/module.rb")
    real_source.write("puts 'deliverable'\n", encoding: "UTF-8")
    refute_equal expected, TwoHeadWu::CapabilityReleaseManager.directory_digest(source)
    real_source.delete

    manager.update(project_id: "pinned", apply: true)
    slot = @state.join("projects/pinned/active/demo").realpath
    refute slot.join("lib/__pycache__").exist?
    refute slot.join(".DS_Store").exist?

    slot.join("lib").chmod(0o755)
    tampered_cache = slot.join("lib/__pycache__")
    tampered_cache.mkpath
    tampered_cache.join("module.pyc").binwrite("tampered-cache")
    error = assert_raises(TwoHeadWu::CapabilityReleaseManager::Error) do
      manager.status(project_id: "pinned")
    end
    assert_includes error.message, "runtime artifact"
  end

  def test_smoke_test_cannot_mutate_release_content
    manager.update(project_id: "compatible", apply: true)
    before = File.readlink(@state.join("projects/compatible/active/demo"))
    release = create_release("1.2.0", "mutating")
    source = @root.join(release.dig("source", "path"))
    source.join("tests/smoke.rb").write(
      "File.open('capability.yaml', 'a') { |file| file.puts('# changed by smoke') }\n",
      encoding: "UTF-8"
    )
    release.fetch("source")["digest"] = TwoHeadWu::CapabilityReleaseManager.directory_digest(source)
    @releases << release
    write_release_catalog

    error = assert_raises(TwoHeadWu::CapabilityReleaseManager::Error) do
      manager().update(project_id: "compatible", apply: true)
    end
    assert_includes error.message, "release content changed during smoke test"
    assert_equal before, File.readlink(@state.join("projects/compatible/active/demo"))
    assert_equal "1.1.0", manager().status(project_id: "compatible").first.fetch("active")
    refute @state.join("releases/demo").children.any? { |item| item.basename.to_s.start_with?("1.2.0--") }
  end

  def test_capability_observation_contains_only_low_cardinality_metadata
    payload = manager.capability_observation_payload(
      project_id: "project-demo",
      capability_id: "demo",
      interface_id: "demo.echo.v1",
      success: true,
      duration_ms: 42,
      conversation_id: "01a06568-de49-7391-b291-b41b2036557d"
    )
    span = payload.dig("resourceSpans", 0, "scopeSpans", 0, "spans", 0)
    attributes = span.fetch("attributes").to_h do |item|
      [item.fetch("key"), item.dig("value", "stringValue")]
    end

    assert_equal "project-demo", attributes.fetch("project.id")
    assert_equal "demo", attributes.fetch("capability.id")
    assert_equal "demo.echo.v1", attributes.fetch("interface.id")
    assert_equal "01a06568-de49-7391-b291-b41b2036557d", attributes.fetch("conversation.id")
    assert_equal "42", attributes.fetch("duration_ms")
    assert_match(/\A[0-9a-f]{32}\z/, span.fetch("traceId"))
    assert_match(/\A[0-9a-f]{16}\z/, span.fetch("spanId"))
    refute attributes.key?("arguments")
    refute attributes.key?("output")
  end

  def test_capability_observation_rejects_untrusted_conversation_metadata
    instance = manager
    assert_nil instance.send(:valid_observability_conversation_id, "prompt-or-account-data")
    assert_equal "01a06568-de49-7391-b291-b41b2036557d",
                 instance.send(:valid_observability_conversation_id, "01a06568-de49-7391-b291-b41b2036557d")
  end

  def test_test_or_embedded_manager_does_not_inherit_process_conversation_metadata
    instance = manager(environment: {})
    instance.define_singleton_method(:capability_observation_payload) do |**_arguments|
      raise "observation payload must not be built without an injected conversation id"
    end

    assert_nil instance.send(
      :emit_capability_observation,
      project_id: "project-demo", capability_id: "demo", interface_id: "demo.echo.v1",
      success: true, duration_ms: 1
    )
  end

  private

  def manager(**options)
    environment = options.delete(:environment) || {}
    TwoHeadWu::CapabilityReleaseManager.new(
      root: @root, state_root: @state, environment: environment, **options
    )
  end

  def run_cli(*arguments)
    args = arguments.dup
    separator = args.index("--") || args.length
    args.insert(separator, "--root", @root.to_s, "--state-root", @state.to_s)
    Open3.capture3(ADAPTER.to_s, *args)
  end

  def permission_contract
    {
      "risk_level" => "low", "network" => "none", "secrets" => "none",
      "filesystem" => { "read" => [], "write" => [] }
    }
  end

  def create_release(version, label, smoke_success: true)
    slug = version.tr(".", "-")
    directory = @root.join("capabilities/demo-#{slug}")
    directory.join("adapters").mkpath
    directory.join("tests").mkpath
    write_yaml(directory.join("capability.yaml"), {
      "schema_version" => 1, "id" => "demo", "version" => version,
      "status" => "active", "permissions" => permission_contract,
      "interfaces" => [{
        "id" => "demo.echo.v1", "type" => "cli", "entrypoint" => "adapters/echo"
      }]
    }, absolute: true)
    adapter = directory.join("adapters/echo")
    adapter.write("#!/usr/bin/env ruby\nputs #{"demo-#{label}:".inspect} + ARGV.join(',')\n", encoding: "UTF-8")
    adapter.chmod(0o755)
    smoke = directory.join("tests/smoke.rb")
    smoke.write(smoke_success ? "exit 0\n" : "warn 'fixture failure'; exit 9\n", encoding: "UTF-8")
    {
      "capability" => "demo", "version" => version, "channel" => "stable", "status" => "available",
      "source" => {
        "kind" => "directory", "path" => directory.relative_path_from(@root).to_s,
        "digest" => TwoHeadWu::CapabilityReleaseManager.directory_digest(directory)
      },
      "interfaces" => { "demo.echo.v1" => { "version" => "1.0.0", "entrypoint" => "adapters/echo" } },
      "permission_digest" => @permission_digest,
      "smoke_tests" => [["ruby", "tests/smoke.rb"]]
    }
  end

  def write_release_catalog
    write_yaml("catalog/capability_releases.yaml", {
      "schema_version" => 1, "updated_at" => "2026-08-25",
      "policy" => {
        "immutable_digest_required" => true, "manifest_identity_required" => true,
        "smoke_tests_before_activation" => true, "network_sources_allowed" => false,
        "stable_prereleases_allowed" => false
      },
      "releases" => @releases
    })
  end

  def write_binding_catalog
    bindings = [
      binding("pinned", "pinned", "1.0.0", false),
      binding("compatible", "compatible", "^1.0.0", true),
      binding("latest", "latest-stable", ">= 0.0.0", true)
    ]
    write_yaml("catalog/project_capability_bindings.yaml", {
      "schema_version" => 1, "updated_at" => "2026-08-25",
      "policy" => {
        "opt_in" => true, "default_update_policy" => "pinned",
        "automatic_update_requires_explicit_binding" => true,
        "discovery_does_not_grant_authorization" => true
      },
      "bindings" => bindings
    })
  end

  def binding(project, policy, requirement, automatic)
    {
      "project" => project, "capability" => "demo", "channel" => "stable",
      "update_policy" => policy, "requirement" => requirement, "automatic" => automatic,
      "runtimes" => %w[codex claude-code], "interfaces" => { "demo.echo.v1" => "^1.0.0" },
      "permission_digest" => @permission_digest
    }
  end

  def write_yaml(path, data, absolute: false)
    target = absolute ? Pathname.new(path) : @root.join(path)
    target.dirname.mkpath
    target.write(YAML.dump(data), encoding: "UTF-8")
  end

  def run_git(*arguments)
    stdout, stderr, status = Open3.capture3(GIT_ISOLATION_ENV, "git", "-C", @root.to_s, *arguments)
    raise "Git fixture command failed: #{stderr}" unless status.success?

    stdout
  end

  def with_environment(changes)
    previous = changes.to_h { |key, _value| [key, ENV[key]] }
    changes.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
