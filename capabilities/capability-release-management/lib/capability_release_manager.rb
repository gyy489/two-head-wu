# frozen_string_literal: true

require "date"
require "digest"
require "fileutils"
require "json"
require "net/http"
require "open3"
require "pathname"
require "rubygems"
require "securerandom"
require "time"
require "timeout"
require "yaml"

module TwoHeadWu
  class CapabilityReleaseManager
    class Error < StandardError; end

    UPDATE_POLICIES = %w[pinned compatible latest-stable].freeze
    CHANNELS = %w[stable beta candidate].freeze
    SOURCE_KINDS = %w[directory git-tree].freeze
    RUNTIME_ARTIFACT_DIRECTORIES = %w[__pycache__ .pytest_cache .ruff_cache .mypy_cache].freeze
    RUNTIME_ARTIFACT_NAMES = %w[.DS_Store .coverage].freeze
    RUNTIME_ARTIFACT_SUFFIXES = %w[.pyc .pyo .swp .swo].freeze
    IDENTIFIER_PATTERN = /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/.freeze
    INTERFACE_PATTERN = /\A[a-z0-9]+(?:[.-][a-z0-9]+)*\z/.freeze
    SEMVER_PATTERN = /\A(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?\z/.freeze
    DEFAULT_SMOKE_TIMEOUT_SECONDS = 60
    GIT_ISOLATION_ENV = {
      "GIT_DIR" => nil,
      "GIT_WORK_TREE" => nil,
      "GIT_COMMON_DIR" => nil,
      "GIT_INDEX_FILE" => nil,
    }.freeze

    attr_reader :root, :state_root, :smoke_timeout_seconds

    def initialize(root:, state_root: nil, smoke_timeout_seconds: DEFAULT_SMOKE_TIMEOUT_SECONDS, environment: ENV)
      @environment = environment
      @root = Pathname.new(root).expand_path.cleanpath
      @state_root = Pathname.new(
        state_root || @environment["WU_CAPABILITY_RELEASE_HOME"] || @root.join("var/capability-releases")
      ).expand_path.cleanpath
      @projects_data = load_yaml("registries/projects_registry.yaml")
      @packages_data = load_yaml("catalog/packages_registry.yaml")
      @resources_data = load_yaml("catalog/resources/infrastructure.yaml")
      @releases_data = load_yaml("catalog/capability_releases.yaml")
      @bindings_data = load_yaml("catalog/project_capability_bindings.yaml")
      @smoke_timeout_seconds = Float(smoke_timeout_seconds)
      unless @smoke_timeout_seconds.positive? && @smoke_timeout_seconds <= 300
        raise Error, "smoke test timeout must be greater than 0 and at most 300 seconds"
      end
      @projects = index_by(@projects_data.fetch("projects"), "id", "project")
      @packages = index_by(@packages_data.fetch("packages"), "id", "package")
      @resources = index_by(@resources_data.fetch("resources"), "id", "resource")
      @bindings = @bindings_data.fetch("bindings")
      @releases = @releases_data.fetch("releases")
      raise Error, "binding collection is not an array" unless @bindings.is_a?(Array)
      raise Error, "release collection is not an array" unless @releases.is_a?(Array)
      validate_catalogs!
    end

    def status(project_id:, capability_id: nil)
      selected_bindings(project_id, capability_id).map do |binding|
        release = resolve_binding(binding)
        active = active_metadata(project_id, binding.fetch("capability"))
        if active && release && active.fetch("version") == release.fetch("version")
          verify_installed_release!(binding, release, active_slot(project_id, binding.fetch("capability")))
        end
        {
          "project" => project_id,
          "capability" => binding.fetch("capability"),
          "policy" => binding.fetch("update_policy"),
          "requirement" => binding.fetch("requirement"),
          "automatic" => binding.fetch("automatic"),
          "active" => active && active.fetch("version"),
          "resolved" => release && release.fetch("version"),
          "state" => release_state(active, release)
        }
      end
    end

    def resolve(project_id:, capability_id: nil)
      selected_bindings(project_id, capability_id).map do |binding|
        release = resolve_binding(binding)
        raise Error, "no compatible release for #{project_id}/#{binding.fetch('capability')}" unless release

        {
          "project" => project_id,
          "capability" => binding.fetch("capability"),
          "version" => release.fetch("version"),
          "channel" => release.fetch("channel"),
          "interfaces" => release.fetch("interfaces"),
          "permission_digest" => release.fetch("permission_digest")
        }
      end
    end

    def update(project_id:, capability_id: nil, automatic: false, apply: false, version: nil)
      raise Error, "automatic update cannot select an explicit version" if automatic && version
      bindings = selected_bindings(project_id, capability_id)
      bindings = bindings.select { |item| automatic_binding?(item) } if automatic
      plans = bindings.map do |binding|
        release = if version
                    compatible_releases(binding).find { |item| item.fetch("version") == version }
                  else
                    resolve_binding(binding)
                  end
        raise Error, "no compatible release for #{project_id}/#{binding.fetch('capability')}" unless release

        active = active_metadata(project_id, binding.fetch("capability"))
        if active && active.fetch("version") == release.fetch("version")
          verify_installed_release!(binding, release, active_slot(project_id, binding.fetch("capability")))
        end
        {
          "project" => project_id,
          "capability" => binding.fetch("capability"),
          "current" => active && active.fetch("version"),
          "target" => release.fetch("version"),
          "action" => active && active.fetch("version") == release.fetch("version") ? "none" : "activate",
          "automatic" => automatic
        }.tap do |plan|
          apply_release(project_id, binding, release) if apply && plan.fetch("action") == "activate"
          plan["applied"] = apply && plan.fetch("action") == "activate"
        end
      end
      { "dry_run" => !apply, "plans" => plans }
    end

    def rollback(project_id:, capability_id:, version:, apply: false)
      raise Error, "rollback requires --apply" unless apply

      binding = selected_bindings(project_id, capability_id).first
      release = compatible_releases(binding).find { |item| item.fetch("version") == version }
      raise Error, "rollback target is not allowed by the current binding: #{version}" unless release

      with_lock(capability_id) do
        slot = installed_slot_for(capability_id, version, release.dig("source", "digest"))
        raise Error, "rollback target is not installed: #{capability_id} #{version}" unless slot&.directory?

        verify_installed_release!(binding, release, slot)
        run_smoke_tests!(release.fetch("smoke_tests"), slot)
        activate!(project_id, capability_id, slot)
      end
      { "project" => project_id, "capability" => capability_id, "active" => version, "rolled_back" => true }
    end

    def invoke(project_id:, capability_id:, runtime_id:, interface_id:, arguments:)
      binding = selected_bindings(project_id, capability_id).first
      unless Array(binding.fetch("runtimes")).include?(runtime_id)
        raise Error, "runtime is not allowed by binding: #{runtime_id}"
      end
      requirement = binding.fetch("interfaces")[interface_id]
      raise Error, "interface is not allowed by binding: #{interface_id}" unless requirement

      active = active_slot(project_id, capability_id)
      raise Error, "capability has no active release: #{project_id}/#{capability_id}" unless active

      active_metadata = load_yaml_path(active.join(".release.yaml"))
      release = compatible_releases(binding).find do |item|
        item.fetch("version") == active_metadata.fetch("version") &&
          item.dig("source", "digest") == active_metadata.fetch("source_digest")
      end
      raise Error, "active release is no longer allowed by the project binding" unless release

      metadata = verify_installed_release!(binding, release, active)
      interface = metadata.fetch("interfaces")[interface_id]
      raise Error, "active release does not export interface: #{interface_id}" unless interface
      unless requirement_for(requirement).satisfied_by?(version_for(interface.fetch("version")))
        raise Error, "active interface version no longer satisfies binding: #{interface_id}"
      end

      entrypoint = confined_path(active, interface.fetch("entrypoint"), "interface entrypoint")
      raise Error, "interface entrypoint is not executable: #{interface_id}" unless entrypoint.file? && entrypoint.executable?

      environment = {
        "TWO_HEAD_WU_CAPABILITY_STATE_ROOT" => state_root.to_s,
        "TWO_HEAD_WU_CAPABILITY_ID" => capability_id,
        "TWO_HEAD_WU_CAPABILITY_INTERFACE_ID" => interface_id,
        "TWO_HEAD_WU_PROJECT_ID" => project_id,
        "TWO_HEAD_WU_PROJECT_ROOT" => root.to_s
      }.merge(resource_environment(project_id, release))
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      pid = Process.spawn(environment, entrypoint.to_s, *arguments, chdir: active.to_s)
      Process.wait(pid)
      status = $?
      emit_capability_observation(
        project_id: project_id,
        capability_id: capability_id,
        interface_id: interface_id,
        success: status.success?,
        duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
      )
      raise Error, "interface exited with status #{status.exitstatus}" unless status.success?

      status.exitstatus
    end

    def capability_observation_payload(project_id:, capability_id:, interface_id:, success:, duration_ms:, conversation_id:)
      now = (Time.now.to_r * 1_000_000_000).to_i.to_s
      attributes = {
        "project.id" => project_id,
        "agent.logical_identity" => "two-head-wu-codex",
        "agent.runtime" => "codex",
        "runtime.surface" => "owner-local-codex",
        "observability.schema" => "3",
        "conversation.id" => conversation_id,
        "event.name" => "two_head_wu.capability_invocation",
        "capability.id" => capability_id,
        "interface.id" => interface_id,
        "success" => success ? "true" : "false",
        "duration_ms" => Integer(duration_ms).to_s
      }.map { |key, value| { "key" => key, "value" => { "stringValue" => value } } }
      {
        "resourceSpans" => [{
          "resource" => { "attributes" => [{
            "key" => "service.name", "value" => { "stringValue" => "two-head-wu-capability-runtime" }
          }] },
          "scopeSpans" => [{
            "scope" => { "name" => "two-head-wu-capability-runtime" },
            "spans" => [{
              "traceId" => SecureRandom.hex(16),
              "spanId" => SecureRandom.hex(8),
              "name" => "two_head_wu.capability_invocation",
              "kind" => 1,
              "startTimeUnixNano" => now,
              "endTimeUnixNano" => now,
              "attributes" => attributes,
              "status" => { "code" => success ? 1 : 2 }
            }]
          }]
        }]
      }
    end

    def self.directory_digest(path, ignored_relative_paths: [])
      root = Pathname.new(path).expand_path.cleanpath
      raise Error, "release source is not a directory: #{root}" unless root.directory?
      raise Error, "release source root must not be a symlink: #{root}" if root.symlink?

      digest = Digest::SHA256.new
      ignored = ignored_relative_paths.each_with_object({}) { |item, output| output[item] = true }
      entries = root.find.to_a.reject { |item| item == root }.sort_by { |item| item.relative_path_from(root).to_s }
      entries.each do |entry|
        relative = entry.relative_path_from(root).to_s
        raise Error, "release source contains a symlink: #{relative}" if entry.symlink?
        next if ignored[relative]
        next if runtime_artifact?(Pathname.new(relative))
        next if entry.directory?
        raise Error, "release source contains a non-file: #{relative}" unless entry.file?

        mode = entry.executable? ? "x" : "-"
        digest << relative << "\0" << mode << "\0"
        File.open(entry, "rb") { |file| digest << file.read(65_536) until file.eof? }
        digest << "\0"
      end
      "sha256:#{digest.hexdigest}"
    end

    def self.runtime_artifact?(relative)
      parts = Pathname.new(relative).each_filename.to_a
      name = parts.last.to_s
      RUNTIME_ARTIFACT_DIRECTORIES.any? { |item| parts.include?(item) } ||
        RUNTIME_ARTIFACT_NAMES.include?(name) ||
        name.start_with?(".coverage.") ||
        RUNTIME_ARTIFACT_SUFFIXES.any? { |suffix| name.end_with?(suffix) }
    end

    def self.permission_digest(permissions)
      "sha256:#{Digest::SHA256.hexdigest(JSON.generate(deep_sort(permissions)))}"
    end

    def self.deep_sort(value)
      case value
      when Hash
        value.keys.map(&:to_s).sort.each_with_object({}) do |key, output|
          original_key = value.key?(key) ? key : value.keys.find { |candidate| candidate.to_s == key }
          output[key] = deep_sort(value.fetch(original_key))
        end
      when Array then value.map { |item| deep_sort(item) }
      else value
      end
    end

    private

    def emit_capability_observation(project_id:, capability_id:, interface_id:, success:, duration_ms:)
      conversation_id = @environment["CODEX_THREAD_ID"].to_s
      conversation_id = @environment["CODEX_SESSION_ID"].to_s if conversation_id.empty?
      conversation_id = valid_observability_conversation_id(conversation_id)
      return unless conversation_id

      payload = capability_observation_payload(
        project_id: project_id,
        capability_id: capability_id,
        interface_id: interface_id,
        success: success,
        duration_ms: duration_ms,
        conversation_id: conversation_id
      )
      request = Net::HTTP::Post.new("/v1/traces")
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(payload)
      http = Net::HTTP.new("127.0.0.1", 4318)
      http.open_timeout = 0.5
      http.read_timeout = 0.5
      http.start { |connection| connection.request(request) }
    rescue SystemCallError, IOError, Timeout::Error, Net::HTTPBadResponse
      nil
    end

    def valid_observability_conversation_id(value)
      pattern = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
      value if value.match?(pattern)
    end

    def load_yaml(relative)
      load_yaml_path(root.join(relative))
    end

    def load_yaml_path(path)
      raise Error, "required registry is missing: #{path}" unless path.file?

      data = YAML.safe_load(path.read(encoding: "UTF-8"), permitted_classes: [Date, Time], aliases: false)
      raise Error, "YAML document is not a mapping: #{path}" unless data.is_a?(Hash)

      data
    rescue Psych::Exception => error
      raise Error, "invalid YAML #{path}: #{error.message}"
    end

    def index_by(items, key, label)
      raise Error, "#{label} collection is not an array" unless items.is_a?(Array)

      items.each_with_object({}) do |item, output|
        raise Error, "invalid #{label} record" unless item.is_a?(Hash)
        value = item.fetch(key)
        raise Error, "duplicate #{label}: #{value}" if output.key?(value)
        output[value] = item
      end
    end

    def validate_catalogs!
      raise Error, "release registry schema version must be 1" unless @releases_data["schema_version"] == 1
      raise Error, "binding registry schema version must be 1" unless @bindings_data["schema_version"] == 1
      expected_release_policy = {
        "immutable_digest_required" => true,
        "manifest_identity_required" => true,
        "smoke_tests_before_activation" => true,
        "network_sources_allowed" => false,
        "stable_prereleases_allowed" => false
      }
      expected_binding_policy = {
        "opt_in" => true,
        "default_update_policy" => "pinned",
        "automatic_update_requires_explicit_binding" => true,
        "discovery_does_not_grant_authorization" => true
      }
      unless @releases_data.fetch("policy") == expected_release_policy
        raise Error, "release registry policy is not the enforced V1 policy"
      end
      unless @bindings_data.fetch("policy") == expected_binding_policy
        raise Error, "binding registry policy is not the enforced V1 policy"
      end

      release_keys = {}
      release_precedence_keys = {}
      @releases.each do |release|
        capability = release.fetch("capability")
        version = release.fetch("version")
        validate_identifier!(capability, "release Capability")
        key = [capability, version]
        raise Error, "duplicate Capability release: #{capability} #{version}" if release_keys[key]
        release_keys[key] = true
        raise Error, "unknown release Capability: #{capability}" unless @packages.key?(capability)
        precedence_key = [capability, release.fetch("channel"), version_for(version).to_s]
        if release_precedence_keys[precedence_key]
          raise Error, "duplicate Capability release precedence: #{capability} #{version}"
        end
        release_precedence_keys[precedence_key] = true
        raise Error, "invalid release channel: #{release['channel']}" unless CHANNELS.include?(release.fetch("channel"))
        raise Error, "invalid release status: #{release['status']}" unless %w[available deprecated disabled].include?(release.fetch("status"))
        validate_source!(release.fetch("source"))
        validate_digest!(release.fetch("permission_digest"), "permission digest")
        validate_release_interfaces!(release.fetch("interfaces"))
        validate_resource_bindings!(release.fetch("resource_bindings", {}))
        validate_smoke_tests!(release.fetch("smoke_tests"))
      end

      binding_keys = {}
      @bindings.each do |binding|
        project_id = binding.fetch("project")
        capability = binding.fetch("capability")
        validate_identifier!(project_id, "binding project")
        validate_identifier!(capability, "binding Capability")
        key = [project_id, capability]
        raise Error, "duplicate project Capability binding: #{project_id}/#{capability}" if binding_keys[key]
        binding_keys[key] = true
        project = @projects[project_id]
        raise Error, "binding references unknown project: #{project_id}" unless project
        raise Error, "binding references unknown Capability: #{capability}" unless @packages.key?(capability)
        unless Array(project.dig("capabilities", "packages")).include?(capability)
          raise Error, "binding exceeds project package authorization: #{project_id}/#{capability}"
        end
        policy = binding.fetch("update_policy")
        raise Error, "invalid update policy: #{policy}" unless UPDATE_POLICIES.include?(policy)
        raise Error, "invalid binding channel: #{binding['channel']}" unless CHANNELS.include?(binding.fetch("channel"))
        if policy == "latest-stable" && binding.fetch("channel") != "stable"
          raise Error, "latest-stable binding requires the stable channel: #{project_id}/#{capability}"
        end
        unless [true, false].include?(binding.fetch("automatic"))
          raise Error, "binding automatic flag must be boolean: #{project_id}/#{capability}"
        end
        validate_binding_requirement!(binding)
        validate_digest!(binding.fetch("permission_digest"), "binding permission digest")
        runtimes = Array(binding.fetch("runtimes"))
        raise Error, "binding has no runtimes: #{project_id}/#{capability}" if runtimes.empty?
        runtimes.each { |runtime| validate_identifier!(runtime, "binding runtime") }
        unknown_runtimes = runtimes - Array(project.fetch("allowed_runtimes"))
        raise Error, "binding exceeds project runtime authorization: #{unknown_runtimes.join(', ')}" unless unknown_runtimes.empty?
        interfaces = binding.fetch("interfaces")
        raise Error, "binding has no interfaces: #{project_id}/#{capability}" unless interfaces.is_a?(Hash) && !interfaces.empty?
        interfaces.each do |id, requirement|
          validate_interface_identifier!(id, "binding interface")
          requirement_for(requirement)
        end
      end
    end

    def validate_source!(source)
      kind = source.fetch("kind")
      raise Error, "invalid release source kind: #{kind}" unless SOURCE_KINDS.include?(kind)
      clean_relative(source.fetch("path"), "release source path")
      validate_digest!(source.fetch("digest"), "release source digest")
      return unless kind == "git-tree"

      revision = source.fetch("revision")
      raise Error, "git-tree revision must be an immutable object ID" unless revision.match?(/\A[0-9a-f]{40,64}\z/)
      raise Error, "git-tree source requires a tree ID" unless source.fetch("tree").match?(/\A[0-9a-f]{40,64}\z/)
    end

    def validate_release_interfaces!(interfaces)
      raise Error, "release has no interfaces" unless interfaces.is_a?(Hash) && !interfaces.empty?
      interfaces.each do |id, interface|
        validate_interface_identifier!(id, "release interface")
        raise Error, "invalid interface record: #{id}" unless interface.is_a?(Hash)
        version_for(interface.fetch("version"))
        clean_relative(interface.fetch("entrypoint"), "interface entrypoint")
      end
    end

    def validate_resource_bindings!(bindings)
      raise Error, "release resource_bindings must be a mapping" unless bindings.is_a?(Hash)
      bindings.each do |resource_id, binding|
        validate_identifier!(resource_id, "release resource binding")
        raise Error, "unknown release resource: #{resource_id}" unless @resources.key?(resource_id)
        raise Error, "invalid release resource binding: #{resource_id}" unless binding.is_a?(Hash)
        unless binding.keys.sort == %w[environment value_key]
          raise Error, "release resource binding fields are invalid: #{resource_id}"
        end
        environment = binding.fetch("environment").to_s
        value_key = binding.fetch("value_key").to_s
        unless environment.match?(/\ATWO_HEAD_WU_[A-Z0-9_]+\z/)
          raise Error, "release resource environment is invalid: #{resource_id}"
        end
        unless value_key.match?(/\A[a-z][a-z0-9_]*\z/)
          raise Error, "release resource value key is invalid: #{resource_id}"
        end
      end
    end

    def validate_smoke_tests!(tests)
      raise Error, "release has no smoke tests" unless tests.is_a?(Array) && !tests.empty?
      tests.each do |command|
        unless command.is_a?(Array) && !command.empty? && command.all? { |item| item.is_a?(String) && !item.empty? }
          raise Error, "smoke tests must be non-empty argument arrays"
        end
      end
    end

    def validate_binding_requirement!(binding)
      requirement = requirement_for(binding.fetch("requirement"))
      return unless binding.fetch("update_policy") == "pinned"

      requirements = requirement.requirements
      unless requirements.length == 1 && requirements.first.first == "="
        raise Error, "pinned binding requires one exact version: #{binding.fetch('project')}/#{binding.fetch('capability')}"
      end
    end

    def validate_digest!(value, label)
      raise Error, "invalid #{label}: #{value}" unless value.to_s.match?(/\Asha256:[0-9a-f]{64}\z/)
    end

    def validate_identifier!(value, label)
      raise Error, "invalid #{label}: #{value}" unless value.to_s.match?(IDENTIFIER_PATTERN)
    end

    def validate_interface_identifier!(value, label)
      raise Error, "invalid #{label}: #{value}" unless value.to_s.match?(INTERFACE_PATTERN)
    end

    def selected_bindings(project_id, capability_id)
      raise Error, "unknown project: #{project_id}" unless @projects.key?(project_id)
      matches = @bindings.select { |item| item.fetch("project") == project_id }
      matches = matches.select { |item| item.fetch("capability") == capability_id } if capability_id
      if capability_id && matches.empty?
        raise Error, "project has no Capability release binding: #{project_id}/#{capability_id}"
      end
      matches.sort_by { |item| item.fetch("capability") }
    end

    def automatic_binding?(binding)
      binding.fetch("automatic") && binding.fetch("update_policy") != "pinned"
    end

    def resolve_binding(binding)
      compatible_releases(binding).max_by { |release| version_for(release.fetch("version")) }
    end

    def compatible_releases(binding)
      capability = binding.fetch("capability")
      requirement = requirement_for(binding.fetch("requirement"))
      @releases.select do |release|
        next false unless release.fetch("capability") == capability
        next false unless release.fetch("status") == "available"
        next false unless release.fetch("channel") == binding.fetch("channel")
        version = version_for(release.fetch("version"))
        next false if binding.fetch("channel") == "stable" && version.prerelease?
        next false unless requirement.satisfied_by?(version)
        next false unless release.fetch("permission_digest") == binding.fetch("permission_digest")
        interfaces_satisfy?(release.fetch("interfaces"), binding.fetch("interfaces"))
      end
    end

    def interfaces_satisfy?(available, required)
      required.all? do |id, requirement|
        interface = available[id]
        interface && requirement_for(requirement).satisfied_by?(version_for(interface.fetch("version")))
      end
    end

    def requirement_for(value)
      text = value.to_s.strip
      if text.start_with?("^")
        base = version_for(text.delete_prefix("^"))
        upper = if base.segments[0].positive?
                  Gem::Version.new("#{base.segments[0] + 1}.0.0")
                elsif base.segments[1].to_i.positive?
                  Gem::Version.new("0.#{base.segments[1] + 1}.0")
                else
                  Gem::Version.new("0.0.#{base.segments[2].to_i + 1}")
                end
        Gem::Requirement.new(">= #{base}", "< #{upper}")
      else
        requirements = text.split(",").map(&:strip)
        raise Error, "empty version requirement" if requirements.empty? || requirements.any?(&:empty?)
        normalized_requirements = requirements.map do |item|
          match = item.match(/\A(?:=|!=|>|<|>=|<=|~>)?\s*(\S+)\z/)
          raise Error, "invalid version requirement #{value.inspect}" unless match
          version_for(match[1])
          item.sub(match[1], match[1].split("+", 2).first)
        end
        Gem::Requirement.new(*normalized_requirements)
      end
    rescue ArgumentError => error
      raise Error, "invalid version requirement #{value.inspect}: #{error.message}"
    end

    def version_for(value)
      text = value.to_s
      raise Error, "version is not Semantic Versioning: #{value}" unless text.match?(SEMVER_PATTERN)
      prerelease = text.split("+", 2).first.split("-", 2)[1]
      if prerelease && prerelease.split(".").any? { |item| item.match?(/\A\d+\z/) && item.length > 1 && item.start_with?("0") }
        raise Error, "numeric prerelease identifiers must not contain leading zeroes: #{value}"
      end

      Gem::Version.new(text.split("+", 2).first)
    rescue ArgumentError => error
      raise Error, "invalid version #{value.inspect}: #{error.message}"
    end

    def release_state(active, release)
      return "unavailable" unless release
      return "not-installed" unless active
      active.fetch("version") == release.fetch("version") ? "current" : "update-available"
    end

    def apply_release(project_id, binding, release)
      capability = binding.fetch("capability")
      with_lock(capability) do
        slot = installed_slot_for(capability, release.fetch("version"), release.dig("source", "digest"))
        installed_now = !slot&.directory?
        slot = install_release!(binding, release) if installed_now
        verify_installed_release!(binding, release, slot)
        run_smoke_tests!(release.fetch("smoke_tests"), slot) unless installed_now
        activate!(project_id, capability, slot)
      end
    end

    def with_lock(capability)
      lock_root = state_root.join("locks")
      FileUtils.mkdir_p(lock_root)
      lock_path = lock_root.join("#{capability}.lock")
      File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |file|
        file.flock(File::LOCK_EX)
        yield
      ensure
        file.flock(File::LOCK_UN) rescue nil
      end
    end

    def install_release!(binding, release)
      source_digest = release.fetch("source").fetch("digest")
      slot = slot_path(release.fetch("capability"), release.fetch("version"), source_digest)
      stage_root = state_root.join(".staging")
      FileUtils.mkdir_p(stage_root)
      stage = stage_root.join("#{release.fetch('capability')}-#{Process.pid}-#{SecureRandom.hex(6)}")
      FileUtils.mkdir_p(stage, mode: 0o700)
      materialize_source!(release.fetch("source"), stage)
      actual_digest = self.class.directory_digest(stage)
      raise Error, "release digest mismatch: expected #{source_digest}, got #{actual_digest}" unless actual_digest == source_digest
      raise Error, "release source uses reserved path: .release.yaml" if stage.join(".release.yaml").exist?

      verify_manifest_contract!(stage, binding, release)
      run_smoke_tests!(release.fetch("smoke_tests"), stage)
      purge_runtime_artifacts!(stage)
      post_smoke_digest = self.class.directory_digest(stage)
      unless post_smoke_digest == source_digest
        raise Error, "release content changed during smoke test: expected #{source_digest}, got #{post_smoke_digest}"
      end

      metadata = {
        "capability" => release.fetch("capability"),
        "version" => release.fetch("version"),
        "source_digest" => source_digest,
        "permission_digest" => release.fetch("permission_digest"),
        "interfaces" => release.fetch("interfaces"),
        "resource_bindings" => release.fetch("resource_bindings", {}),
        "installed_at" => Time.now.utc.iso8601
      }
      stage.join(".release.yaml").write(YAML.dump(metadata), encoding: "UTF-8")
      FileUtils.mkdir_p(slot.dirname)
      File.rename(stage, slot)
      moved = true
      freeze_slot!(slot)
      slot
    rescue StandardError
      cleanup = moved ? slot : stage
      FileUtils.chmod_R(0o700, cleanup) if cleanup && cleanup.exist?
      FileUtils.rm_rf(cleanup) if cleanup && cleanup.exist?
      raise
    end

    def materialize_source!(source, stage)
      relative = clean_relative(source.fetch("path"), "release source path")
      unless relative.each_filename.first == "capabilities"
        raise Error, "release source must be owned by capabilities/: #{relative}"
      end
      case source.fetch("kind")
      when "directory"
        source_path = confined_path(root, relative.to_s, "release source")
        raise Error, "release source is missing: #{relative}" unless source_path.directory?
        source_real = source_path.realpath.cleanpath
        capabilities_real = root.join("capabilities").realpath.cleanpath
        unless inside?(source_real, capabilities_real)
          raise Error, "release source escapes capabilities/ through a symlink: #{relative}"
        end
        actual = self.class.directory_digest(source_path)
        raise Error, "release source digest mismatch: expected #{source.fetch('digest')}, got #{actual}" unless actual == source.fetch("digest")
        copy_directory_contents(source_path, stage)
      when "git-tree"
        materialize_git_tree!(source, relative, stage)
      else
        raise Error, "unsupported source kind: #{source.fetch('kind')}"
      end
    end

    def materialize_git_tree!(source, relative, stage)
      revision = source.fetch("revision")
      tree_ref = "#{revision}:#{relative}"
      tree, error, status = capture_git("rev-parse", tree_ref)
      raise Error, "cannot resolve registered Git tree: #{error.strip}" unless status.success?
      unless tree.strip == source.fetch("tree")
        raise Error, "registered Git tree ID mismatch"
      end

      archive = stage.dirname.join("#{stage.basename}.tar")
      extract = stage.dirname.join("#{stage.basename}.extract")
      FileUtils.mkdir_p(extract)
      run_git!("archive", "--format=tar", "-o", archive.to_s, revision, relative.to_s)
      run_command!(["tar", "-xf", archive.to_s, "-C", extract.to_s], root)
      extracted = extract.join(relative)
      raise Error, "Git archive omitted registered source path" unless extracted.directory?
      copy_directory_contents(extracted, stage)
    ensure
      FileUtils.rm_f(archive) if archive
      FileUtils.rm_rf(extract) if extract
    end

    def run_smoke_tests!(tests, stage)
      tests.each do |command|
        stdout, stderr, status = capture_smoke_test(command, stage)
        next if status.success?

        detail = [stdout, stderr].join("\n").strip[0, 1200]
        raise Error, "release smoke test failed (#{command.join(' ')}): #{detail}"
      end
    end

    def capture_smoke_test(command, stage)
      stdout = ""
      stderr = ""
      status = nil
      Open3.popen3(
        { "WU_RELEASE_VALIDATION" => "1" }, *command,
        chdir: stage.to_s, pgroup: true
      ) do |input, output, error, waiter|
        input.close
        output_reader = Thread.new { output.read }
        error_reader = Thread.new { error.read }
        unless waiter.join(smoke_timeout_seconds)
          terminate_process_group(waiter.pid, waiter)
          stdout = output_reader.value
          stderr = error_reader.value
          detail = [stdout, stderr].join("\n").strip[0, 1200]
          raise Error, "release smoke test timed out after #{smoke_timeout_seconds} seconds (#{command.join(' ')}): #{detail}"
        end
        stdout = output_reader.value
        stderr = error_reader.value
        status = waiter.value
      end
      [stdout, stderr, status]
    rescue Errno::ENOENT => error
      raise Error, "release smoke test executable is missing (#{command.first}): #{error.message}"
    end

    def terminate_process_group(pid, waiter)
      Process.kill("TERM", -pid)
      return if waiter.join(2)

      Process.kill("KILL", -pid)
      waiter.join
    rescue Errno::ESRCH, Errno::ECHILD
      waiter.join rescue nil
    end

    def run_command!(command, directory)
      stdout, stderr, status = Open3.capture3(*command, chdir: directory.to_s)
      return stdout if status.success?

      raise Error, "command failed (#{command.join(' ')}): #{stderr.strip[0, 1200]}"
    end

    def capture_git(*arguments)
      Open3.capture3(GIT_ISOLATION_ENV, "git", "-C", root.to_s, *arguments)
    end

    def run_git!(*arguments)
      stdout, stderr, status = capture_git(*arguments)
      return stdout if status.success?

      raise Error, "Git command failed (#{arguments.join(' ')}): #{stderr.strip[0, 1200]}"
    end

    def activate!(project_id, capability, slot)
      active_dir = state_root.join("projects", project_id, "active")
      FileUtils.mkdir_p(active_dir)
      target = active_dir.join(capability)
      temporary = active_dir.join(".#{capability}.new-#{Process.pid}-#{SecureRandom.hex(4)}")
      relative_target = slot.relative_path_from(active_dir)
      temporary.make_symlink(relative_target)
      File.rename(temporary, target)
    ensure
      FileUtils.rm_f(temporary) if temporary && (temporary.exist? || temporary.symlink?)
    end

    def copy_directory_contents(source, destination)
      source.children.each do |child|
        FileUtils.cp_r(child.to_s, destination.to_s, preserve: true)
      end
      purge_runtime_artifacts!(destination)
    end

    def purge_runtime_artifacts!(directory)
      entries = directory.find.to_a.reject { |item| item == directory }
      entries.select { |item| self.class.runtime_artifact?(item.relative_path_from(directory)) }
             .sort_by { |item| -item.each_filename.to_a.length }
             .each { |item| item.directory? && !item.symlink? ? FileUtils.rm_rf(item) : FileUtils.rm_f(item) }
    end

    def reject_runtime_artifacts!(directory)
      artifact = directory.find.find do |item|
        item != directory && self.class.runtime_artifact?(item.relative_path_from(directory))
      end
      if artifact
        raise Error, "installed release contains a runtime artifact: #{artifact.relative_path_from(directory)}"
      end
    end

    def active_slot(project_id, capability)
      pointer = state_root.join("projects", project_id, "active", capability)
      return nil unless pointer.symlink?

      resolved = Pathname.new(File.realpath(pointer)).cleanpath
      releases_root = Pathname.new(File.realpath(state_root.join("releases"))).cleanpath
      unless inside?(resolved, releases_root)
        raise Error, "active release pointer escapes managed state: #{project_id}/#{capability}"
      end
      resolved
    rescue Errno::ENOENT
      raise Error, "active release pointer is broken: #{project_id}/#{capability}"
    end

    def active_metadata(project_id, capability)
      slot = active_slot(project_id, capability)
      slot && load_yaml_path(slot.join(".release.yaml"))
    end

    def installed_slot_for(capability, version, digest)
      candidate = slot_path(capability, version, digest)
      candidate.directory? ? candidate : nil
    end

    def slot_path(capability, version, digest)
      suffix = digest.delete_prefix("sha256:")[0, 16]
      state_root.join("releases", capability, "#{version}--#{suffix}")
    end

    def verify_installed_release!(binding, release, slot)
      metadata = load_yaml_path(slot.join(".release.yaml"))
      verify_installed_metadata!(binding, release, metadata)
      reject_runtime_artifacts!(slot)
      actual_digest = self.class.directory_digest(slot, ignored_relative_paths: [".release.yaml"])
      unless actual_digest == release.dig("source", "digest")
        raise Error, "installed release content digest mismatch: expected #{release.dig('source', 'digest')}, got #{actual_digest}"
      end
      verify_manifest_contract!(slot, binding, release)
      metadata
    end

    def verify_manifest_contract!(directory, binding, release)
      manifest = load_yaml_path(directory.join("capability.yaml"))
      unless manifest.fetch("id") == release.fetch("capability") && manifest.fetch("version") == release.fetch("version")
        raise Error, "release manifest identity/version mismatch"
      end

      actual_permission_digest = self.class.permission_digest(manifest.fetch("permissions"))
      unless actual_permission_digest == release.fetch("permission_digest") &&
             actual_permission_digest == binding.fetch("permission_digest")
        raise Error, "release permission contract mismatch"
      end

      manifest_interfaces = index_by(manifest.fetch("interfaces"), "id", "manifest interface")
      release.fetch("interfaces").each do |id, interface|
        declared = manifest_interfaces[id]
        raise Error, "release manifest does not export interface: #{id}" unless declared
        unless declared.fetch("entrypoint") == interface.fetch("entrypoint")
          raise Error, "release interface entrypoint disagrees with manifest: #{id}"
        end
        entrypoint = confined_path(directory, interface.fetch("entrypoint"), "interface entrypoint")
        unless entrypoint.file? && entrypoint.executable?
          raise Error, "release interface entrypoint is not executable: #{id}"
        end
      end
    end

    def freeze_slot!(slot)
      entries = slot.find.to_a
      files = entries.reject(&:directory?)
      directories = entries.select(&:directory?).sort_by { |item| -item.each_filename.to_a.length }
      files.each { |item| File.chmod(item.executable? ? 0o555 : 0o444, item) }
      directories.each { |item| File.chmod(0o555, item) }
    end

    def verify_installed_metadata!(binding, release, metadata)
      raise Error, "installed release identity mismatch" unless metadata.fetch("capability") == release.fetch("capability")
      raise Error, "installed release version mismatch" unless metadata.fetch("version") == release.fetch("version")
      raise Error, "installed release digest mismatch" unless metadata.fetch("source_digest") == release.dig("source", "digest")
      unless metadata.fetch("permission_digest") == binding.fetch("permission_digest") &&
             metadata.fetch("permission_digest") == release.fetch("permission_digest")
        raise Error, "installed permission contract mismatch"
      end
      unless interfaces_satisfy?(metadata.fetch("interfaces"), binding.fetch("interfaces"))
        raise Error, "installed interface contract mismatch"
      end
      unless metadata.fetch("resource_bindings", {}) == release.fetch("resource_bindings", {})
        raise Error, "installed resource binding contract mismatch"
      end
    end

    def resource_environment(project_id, release)
      bindings = release.fetch("resource_bindings", {})
      return {} if bindings.empty?

      project = @projects.fetch(project_id)
      allowed = Array(project.dig("resources", "allowed"))
      bindings.each_with_object({}) do |(resource_id, contract), environment|
        raise Error, "project is not authorized for resource: #{resource_id}" unless allowed.include?(resource_id)

        binding_path = machine_resource_binding_path(resource_id)
        raise Error, "machine resource binding is unavailable: #{resource_id}" unless binding_path.file?
        raise Error, "machine resource binding must not be a symlink: #{resource_id}" if binding_path.symlink?
        payload = JSON.parse(binding_path.read(encoding: "UTF-8"))
        unless payload.is_a?(Hash) && payload["schema_version"] == 1 && payload["resource_id"] == resource_id
          raise Error, "machine resource binding is invalid: #{resource_id}"
        end
        value = Pathname.new(payload.fetch(contract.fetch("value_key")).to_s).expand_path.cleanpath
        unless value.absolute? && value.directory? && !value.symlink?
          raise Error, "machine resource target is unavailable: #{resource_id}"
        end
        environment[contract.fetch("environment")] = value.to_s
      rescue JSON::ParserError, KeyError => error
        raise Error, "machine resource binding is invalid: #{resource_id}: #{error.message}"
      end
    end

    def machine_resource_binding_path(resource_id)
      legacy = ENV["WU_RESEARCH_LIBRARY_BINDING_FILE"].to_s
      if resource_id == "private-data-service" && !legacy.empty?
        return Pathname.new(legacy).expand_path.cleanpath
      end

      binding_root = ENV["WU_RESOURCE_BINDING_ROOT"].to_s
      base = binding_root.empty? ? root.join("var/resource-bindings") : Pathname.new(binding_root).expand_path.cleanpath
      base.join("#{resource_id}.json")
    end

    def clean_relative(value, label)
      path = Pathname.new(value.to_s)
      raise Error, "#{label} must be relative: #{value}" if path.absolute?
      cleaned = path.cleanpath
      raise Error, "#{label} escapes its root: #{value}" if cleaned.to_s == ".." || cleaned.to_s.start_with?("../")
      raise Error, "#{label} is empty" if cleaned.to_s == "."
      cleaned
    end

    def confined_path(base, relative, label)
      candidate = Pathname.new(base).join(clean_relative(relative, label)).cleanpath
      raise Error, "#{label} escapes its root: #{relative}" unless inside?(candidate, Pathname.new(base).cleanpath)
      candidate
    end

    def inside?(candidate, base)
      candidate == base || candidate.to_s.start_with?("#{base}#{File::SEPARATOR}")
    end
  end
end
