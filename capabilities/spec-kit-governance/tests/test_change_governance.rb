# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"
require "yaml"

require_relative "../lib/change_governance"

class ChangeGovernanceTest < Minitest::Test
  GIT_ISOLATION_ENV = {
    "GIT_DIR" => nil,
    "GIT_WORK_TREE" => nil,
    "GIT_COMMON_DIR" => nil,
    "GIT_INDEX_FILE" => nil
  }.freeze

  def with_project
    Dir.mktmpdir("two-head-wu-change-governance") do |directory|
      run_git(directory, "init", "-q")
      run_git(directory, "config", "user.email", "test@example.invalid")
      run_git(directory, "config", "user.name", "Test")
      write(directory, "catalog/documentation_registry.yaml", {
        "modules" => [
          { "id" => "module-a" },
          { "id" => "module-b" }
        ]
      }.to_yaml)
      write(directory, "catalog/packages_registry.yaml", {
        "packages" => [
          { "id" => "cap-a" },
          { "id" => "cap-b" }
        ]
      }.to_yaml)
      write(directory, "README.md", "fixture\n")
      run_git(directory, "add", ".")
      run_git(directory, "commit", "-qm", "baseline")
      yield directory, TwoHeadWu::ChangeGovernance.new(directory)
    end
  end

  def test_valid_capsule_and_scope_pass
    with_project do |root, governance|
      create_capsule(root, writable_paths: ["src/**", "specs/004-test/**"])
      write(root, "src/example.rb", "puts :ok\n")
      run_git(root, "add", ".")

      result = governance.gate!("staged")
      assert_equal "004-test", result.fetch("active_change").fetch("id")
      assert_equal 1, governance.validate_all!.fetch("active").length
    end
  end

  def test_completed_capsule_preserves_retired_module_ids
    with_project do |root, governance|
      create_capsule(root, writable_paths: ["src/**", "specs/004-test/**"])
      capsule = File.join(root, "specs/004-test/change.yaml")
      data = YAML.safe_load(File.read(capsule, encoding: "UTF-8"), aliases: false)
      data["status"] = "completed"
      data["affected_modules"] = ["retired-module"]
      data["implementation_order"] = ["retired-module"]
      write(root, "specs/004-test/change.yaml", data.to_yaml)

      assert_empty governance.validate_all!.fetch("active")
    end
  end

  def test_feature_selector_scopes_parallel_active_capsules_to_this_worktree
    with_project do |root, governance|
      create_capsule(root, writable_paths: ["src/**", "specs/004-test/**"])
      first = YAML.safe_load(File.read(File.join(root, "specs/004-test/change.yaml")), aliases: false)
      second = Marshal.load(Marshal.dump(first))
      second["id"] = "005-parallel"
      second["spec"] = "specs/005-parallel/spec.md"
      second["plan"] = "specs/005-parallel/plan.md"
      second["tasks"] = "specs/005-parallel/tasks.md"
      second["writable_paths"] = ["src/**", "specs/005-parallel/**"]
      write(root, "specs/005-parallel/spec.md", "# Spec\n")
      write(root, "specs/005-parallel/plan.md", "# Plan\n")
      write(root, "specs/005-parallel/tasks.md", "# Tasks\n")
      write(root, "specs/005-parallel/change.yaml", second.to_yaml)
      write(root, ".specify/feature.json", JSON.generate({ "feature_directory" => "specs/005-parallel" }))

      result = governance.validate_all!
      assert_equal ["005-parallel"], result.fetch("active").map { |item| item.fetch("id") }
    end
  end

  def test_more_than_ten_files_requires_capsule
    with_project do |root, governance|
      11.times { |index| write(root, "src/file-#{index}.txt", "x\n") }
      run_git(root, "add", ".")

      error = assert_raises(TwoHeadWu::ChangeGovernanceError) { governance.gate!("staged") }
      assert_includes error.message, "require Spec, Plan, and Change Capsule"
    end
  end

  def test_outside_writable_paths_fails
    with_project do |root, governance|
      create_capsule(root, writable_paths: ["src/**", "specs/004-test/**"])
      write(root, "outside.txt", "no\n")
      run_git(root, "add", ".")

      error = assert_raises(TwoHeadWu::ChangeGovernanceError) { governance.gate!("staged") }
      assert_includes error.message, "outside writable_paths: outside.txt"
    end
  end

  def test_staged_gate_rejects_unstaged_capsule_evidence
    with_project do |root, governance|
      create_capsule(root, writable_paths: ["src/**", "specs/004-test/**"])
      write(root, "src/example.rb", "puts :ok\n")
      run_git(root, "add", "src/example.rb")

      error = assert_raises(TwoHeadWu::ChangeGovernanceError) { governance.gate!("staged") }
      assert_includes error.message, "tracked or staged governance evidence: specs/004-test/change.yaml"
    end
  end

  def test_staged_gate_rejects_unstaged_capsule_edits
    with_project do |root, governance|
      create_capsule(root, writable_paths: ["src/**", "specs/004-test/**"])
      write(root, "src/example.rb", "puts :ok\n")
      run_git(root, "add", ".")
      capsule = File.join(root, "specs/004-test/change.yaml")
      File.open(capsule, "a", encoding: "UTF-8") { |file| file.write("# unstaged widening\n") }

      error = assert_raises(TwoHeadWu::ChangeGovernanceError) { governance.gate!("staged") }
      assert_includes error.message, "refuses unstaged governance evidence changes: specs/004-test/change.yaml"
    end
  end

  def test_more_than_eight_hundred_effective_lines_fails
    with_project do |root, governance|
      create_capsule(root, writable_paths: ["src/**", "specs/004-test/**"])
      write(root, "src/large.txt", (1..801).map { |index| "line #{index}\n" }.join)
      run_git(root, "add", ".")

      error = assert_raises(TwoHeadWu::ChangeGovernanceError) { governance.gate!("staged") }
      assert_includes error.message, "exceed 800"
    end
  end

  def test_cross_capability_change_requires_capsule
    with_project do |root, governance|
      write(root, "capabilities/cap-a/a.txt", "a\n")
      write(root, "capabilities/cap-b/b.txt", "b\n")
      run_git(root, "add", ".")

      error = assert_raises(TwoHeadWu::ChangeGovernanceError) { governance.gate!("staged") }
      assert_includes error.message, "cross-capability change requires"
    end
  end

  private

  def create_capsule(root, writable_paths:)
    write(root, "specs/004-test/spec.md", "# Spec\n")
    write(root, "specs/004-test/plan.md", "# Plan\n")
    write(root, "specs/004-test/tasks.md", "# Tasks\n")
    data = {
      "schema_version" => 1,
      "id" => "004-test",
      "status" => "in-progress",
      "goal" => "test",
      "spec" => "specs/004-test/spec.md",
      "plan" => "specs/004-test/plan.md",
      "tasks" => "specs/004-test/tasks.md",
      "affected_modules" => ["module-a"],
      "writable_paths" => writable_paths,
      "forbidden_paths" => ["private/**"],
      "invariants" => ["preserve fixture"],
      "dependencies" => [],
      "implementation_order" => ["module-a"],
      "acceptance_commands" => ["ruby test.rb"],
      "documentation_impact" => {
        "required" => true,
        "modules" => ["module-a"],
        "update_command" => "wu 更新说明"
      },
      "migration" => { "required" => false, "plan" => "none" },
      "rollback" => { "strategy" => "revert" },
      "delivery" => {
        "max_files_without_spec" => 10,
        "max_effective_lines_per_commit" => 800,
        "commits" => [{ "id" => "one", "scope" => "fixture" }]
      },
      "review" => {
        "mode" => "fresh-context",
        "shared_inputs" => %w[spec plan change-capsule diff test-evidence migration-evidence rollback-evidence],
        "original_chat_shared" => false
      }
    }
    write(root, "specs/004-test/change.yaml", data.to_yaml)
  end

  def write(root, relative, content)
    path = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content, encoding: "UTF-8")
  end

  def run_git(root, *arguments)
    stdout, stderr, status = Open3.capture3(GIT_ISOLATION_ENV, "git", *arguments, chdir: root)
    raise "git #{arguments.join(' ')} failed: #{stderr}" unless status.success?

    stdout
  end
end
