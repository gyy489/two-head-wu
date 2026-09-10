# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "pathname"
require "tmpdir"
require "yaml"

require_relative "../../core/lib/skill_policy"

class SkillPolicyTest < Minitest::Test
  def setup
    @temporary = Pathname.new(Dir.mktmpdir("two-head-wu-skill-policy-"))
    @workspace = @temporary.join("workspace")
    FileUtils.mkdir_p(@workspace.join(".agents/skills"))
    @runtime_builtin_root = @temporary.join("runtime-builtin")
    @user_global_root = @temporary.join("user-global")
    write_skill("core", "Core routing and skill management.")
    write_skill("nested", "Nested package projection.", nested: true)
    write_skill("cold", "Cold academic paper writing analysis.", resource: true)
    write_external_skill(@runtime_builtin_root, "builtin", "Runtime-provided Skill.")
    write_external_skill(@user_global_root, "personal", "User-global Skill.")
    write_registries
    @policy = TwoHeadWu::SkillPolicy.new(@temporary)
  end

  def teardown
    FileUtils.remove_entry(@temporary) if @temporary&.exist?
  end

  def test_overlapping_stacks_are_deduplicated_across_global_and_project_profiles
    assert_equal ["core"], @policy.global_hot_skills("codex")
    assert_equal ["nested"], @policy.project_hot_skills("project", "agent", "codex")
    assert_equal %w[core nested], @policy.resolved_hot_skills("project", "agent", "codex")
    assert_equal %w[cold core nested], @policy.eligible_catalog_skills("project", "agent", "codex")
  end

  def test_projection_hides_nested_skill_entrypoints_and_rewrites_links
    projection = @policy.ensure_projection("nested", "codex")

    assert projection.join("SKILL.md").file?
    refute projection.join("references/vendor/SKILL.md").exist?
    assert projection.join("references/vendor/SKILL.resource.md").file?
    assert_includes projection.join("SKILL.md").read, "references/vendor/SKILL.resource.md"
    assert_equal [projection.join("SKILL.md")], Dir.glob(projection.join("**/SKILL.md").to_s).map { |item| Pathname.new(item) }
  end

  def test_catalog_search_load_and_bounded_resource_read
    results = @policy.catalog_search(
      "paper writing", project_id: "project", agent_id: "agent", runtime_id: "codex"
    )
    assert_equal "cold", results.first.fetch("skill_id")

    loaded = @policy.catalog_load(
      "cold", project_id: "project", agent_id: "agent", runtime_id: "codex"
    )
    assert_equal false, loaded.fetch("scripts_authorized")
    assert_includes loaded.fetch("content"), "Cold academic paper writing"

    resource = @policy.catalog_read(
      "cold", "references/notes.md", project_id: "project", agent_id: "agent", runtime_id: "codex"
    )
    assert_equal "supporting notes\n", resource.fetch("content")
    assert_raises(TwoHeadWu::SkillPolicy::Error) do
      @policy.catalog_read(
        "cold", "../outside", project_id: "project", agent_id: "agent", runtime_id: "codex"
      )
    end
  end

  def test_approval_is_bound_to_the_current_digest
    data = JSON.parse(@temporary.join("skills/registries/skill_releases.json").read)
    data.fetch("current")["cold"] = "sha256:changed"
    data.fetch("releases") << {
      "skill_id" => "cold",
      "digest" => "sha256:changed",
      "snapshot_path" => "skills/releases/cold/current"
    }
    @temporary.join("skills/registries/skill_releases.json").write(JSON.pretty_generate(data))
    changed = TwoHeadWu::SkillPolicy.new(@temporary)

    assert_nil changed.approved_release_for("cold", "codex")
    assert_raises(TwoHeadWu::SkillPolicy::Error) do
      changed.catalog_load(
        "cold", project_id: "project", agent_id: "agent", runtime_id: "codex"
      )
    end
  end

  def test_visibility_budget_includes_runtime_and_user_global_layers
    budget = @policy.visibility_budget("project", "agent", "codex")

    assert_equal 2, budget.fetch("managed")
    assert_equal 1, budget.fetch("runtime_builtin")
    assert_equal 1, budget.fetch("user_global")
    assert_equal 4, budget.fetch("total")
  end

  def test_visibility_budget_parses_current_codex_plugin_json
    plugin_root = @temporary.join("plugin")
    write_external_skill(plugin_root, "plugin-skill", "Plugin-provided Skill.")
    executable = @temporary.join("codex")
    executable.write(<<~SH)
      #!/bin/sh
      printf '%s' '#{JSON.generate(
        "installed" => [{
          "pluginId" => "sample@example",
          "installed" => true,
          "enabled" => true,
          "source" => { "path" => plugin_root.to_s }
        }],
        "available" => []
      )}'
    SH
    executable.chmod(0o755)
    @policy.runtimes.fetch("codex").fetch("executable")["command"] = executable.to_s
    assert_equal executable.to_s, @policy.runtimes.dig("codex", "executable", "command")

    stdout, stderr, status = Open3.capture3(executable.to_s, "plugin", "list")
    assert status.success?, stderr
    assert JSON.parse(stdout).fetch("installed").any?
    inventory = @policy.send(:codex_plugin_inventory)
    budget = @policy.visibility_budget("project", "agent", "codex")

    assert_equal ["sample@example"], inventory.map { |item| item.fetch("selector") }
    assert_equal 1, budget.fetch("plugin")
    assert_equal ["sample@example"], budget.fetch("plugin_packages")
    assert_equal 5, budget.fetch("total")
  end

  private

  def write(path, content)
    target = @temporary.join(path)
    FileUtils.mkdir_p(target.dirname)
    target.write(content)
  end

  def write_skill(name, description, nested: false, resource: false)
    root = @temporary.join("skills/releases", name, "current")
    FileUtils.mkdir_p(root)
    suffix = nested ? "\nSee [vendor](references/vendor/SKILL.md).\n" : "\n"
    root.join("SKILL.md").write(
      "---\nname: #{name}\ndescription: #{description}\n---\n\n# #{name}\n#{suffix}"
    )
    if nested
      FileUtils.mkdir_p(root.join("references/vendor"))
      root.join("references/vendor/SKILL.md").write("---\nname: vendor\ndescription: Nested.\n---\n")
    end
    if resource
      FileUtils.mkdir_p(root.join("references"))
      root.join("references/notes.md").write("supporting notes\n")
    end
  end

  def write_external_skill(root, name, description)
    target = root.join(name)
    FileUtils.mkdir_p(target)
    target.join("SKILL.md").write("---\nname: #{name}\ndescription: #{description}\n---\n")
  end

  def write_registries
    write("registries/capabilities_registry.yaml", {
      "skill_registry" => "skills/registries/skills_registry.yaml",
      "profile_registry" => "skills/registries/skill_profiles.yaml",
      "release_registry" => "skills/registries/skill_releases.json"
    }.to_yaml)
    write("skills/registries/skills_registry.yaml", {
      "skills" => %w[core nested cold].map do |name|
        { "name" => name, "status" => "active", "category" => "test", "purpose" => "#{name} purpose" }
      end
    }.to_yaml)
    write("skills/registries/skill_profiles.yaml", {
      "policy" => {
        "global_profiles" => { "codex" => "global" },
        "project_discovery_roots" => { "codex" => ".agents/skills" },
        "project_overlay_manifests" => { "codex" => ".two-head-wu-codex-profile.json" },
        "max_project_skills" => 10,
        "max_visible_descriptions" => 20,
        "max_description_characters" => 10_000,
        "default_search_top_k" => 5,
        "max_search_top_k" => 10,
        "max_resource_bytes" => 4096
      },
      "stacks" => {
        "global-stack" => { "skills" => ["core"], "compatibility" => { "codex" => "native" } },
        "project-a" => { "skills" => ["nested"], "compatibility" => { "codex" => "native" } },
        "project-b" => { "skills" => ["nested"], "compatibility" => { "codex" => "native" } },
        "catalog" => { "skills" => ["cold"], "compatibility" => { "codex" => "native" } }
      },
      "profiles" => {
        "global" => { "stacks" => ["global-stack"], "catalog_stacks" => [], "hot_skill_budget" => 10 },
        "project-profile" => {
          "stacks" => %w[project-a project-b], "catalog_stacks" => ["catalog"], "hot_skill_budget" => 10
        }
      },
      "bindings" => [
        { "project" => "project", "agent" => "agent", "runtime" => "codex", "profile" => "project-profile" }
      ]
    }.to_yaml)
    releases = %w[core nested cold].map do |name|
      { "skill_id" => name, "digest" => "sha256:#{name}", "snapshot_path" => "skills/releases/#{name}/current" }
    end
    write("skills/registries/skill_releases.json", JSON.pretty_generate(
      "releases" => releases,
      "approvals" => %w[core nested cold].map do |name|
        { "skill_id" => name, "digest" => "sha256:#{name}", "decision" => "approved", "runtimes" => ["codex"] }
      end,
      "current" => %w[core nested cold].to_h { |name| [name, "sha256:#{name}"] }
    ))
    write("registries/projects_registry.yaml", {
      "projects" => [{ "id" => "project", "workspace" => @workspace.to_s, "allowed_runtimes" => ["codex"] }]
    }.to_yaml)
    write("registries/runtimes_registry.yaml", {
      "runtimes" => [{
        "id" => "codex",
        "executable" => { "command" => "/usr/bin/false" },
        "skill_surface" => { "managed_path" => "skills/.runtime/codex/global/skills" },
        "discovery_roots" => [
          { "path" => @runtime_builtin_root.to_s, "budget_class" => "runtime_builtin" },
          { "path" => @user_global_root.to_s, "budget_class" => "user_global" }
        ]
      }]
    }.to_yaml)
    write("registries/agents_registry.yaml", { "agents" => [{ "id" => "agent" }] }.to_yaml)
  end
end
