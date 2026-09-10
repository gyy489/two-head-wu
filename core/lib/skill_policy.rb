# frozen_string_literal: true

require "date"
require "digest"
require "fileutils"
require "find"
require "json"
require "open3"
require "pathname"
require "set"
require "time"
require "yaml"

begin
  require "sqlite3"
rescue LoadError
  # Catalog search keeps a deterministic in-memory fallback when sqlite3 is unavailable.
end

module TwoHeadWu
  class SkillPolicy
    class Error < StandardError; end

    EXPOSED_COMPATIBILITY = %w[native compatible].freeze
    PROJECTION_MARKER = ".two-head-wu-projection.json"
    PROJECT_MOUNT_MARKER = ".two-head-wu-managed.json"
    TEXT_EXTENSIONS = %w[.md .txt .yaml .yml .json .toml].freeze

    attr_reader :root, :profile_data, :release_data, :skills, :projects, :runtimes, :agents

    def initialize(root)
      @root = Pathname.new(root).expand_path.cleanpath
      capabilities = load_yaml("registries/capabilities_registry.yaml")
      @profile_registry_path = expand_path(capabilities.fetch("profile_registry", "skills/registries/skill_profiles.yaml"))
      @release_registry_path = expand_path(capabilities.fetch("release_registry", "skills/registries/skill_releases.json"))
      @skill_registry_path = expand_path(capabilities.fetch("skill_registry", "skills/registries/skills_registry.yaml"))
      @profile_data = load_yaml(@profile_registry_path)
      @release_data = load_json(@release_registry_path)
      @skills = index_by(load_yaml(@skill_registry_path).fetch("skills"), "name")
      @projects = index_by(load_yaml("registries/projects_registry.yaml").fetch("projects"), "id")
      @runtimes = index_by(load_yaml("registries/runtimes_registry.yaml").fetch("runtimes"), "id")
      @agents = index_by(load_yaml("registries/agents_registry.yaml").fetch("agents"), "id")
      @stacks = @profile_data.fetch("stacks")
      @profiles = @profile_data.fetch("profiles")
      @bindings = Array(@profile_data.fetch("bindings"))
      @releases = Array(@release_data.fetch("releases")).each_with_object({}) do |item, index|
        index[[item.fetch("skill_id"), item.fetch("digest")]] = item
      end
      @approvals = Array(@release_data.fetch("approvals"))
      @current = @release_data.fetch("current")
    end

    def global_profile_id(runtime_id)
      @profile_data.dig("policy", "global_profiles", runtime_id) ||
        raise(Error, "no global Skill profile for runtime #{runtime_id}")
    end

    def global_hot_skills(runtime_id)
      hot_skills(global_profile_id(runtime_id), runtime_id)
    end

    def project_profile_id(project_id, agent_id, runtime_id)
      binding = binding_for(project_id, agent_id, runtime_id)
      binding && binding.fetch("profile")
    end

    def binding_for(project_id, agent_id, runtime_id)
      @bindings.find do |item|
        item.fetch("project") == project_id && item.fetch("agent") == agent_id &&
          item.fetch("runtime") == runtime_id
      end
    end

    def bindings_for_runtime(runtime_id)
      @bindings.select { |item| item.fetch("runtime") == runtime_id }
    end

    def hot_skills(profile_id, runtime_id)
      profile = profile_for(profile_id)
      names = skills_for_stacks(Array(profile["stacks"]), runtime_id)
      budget = Integer(profile.fetch("hot_skill_budget", policy.fetch("max_project_skills")))
      raise Error, "profile #{profile_id} exceeds hot Skill budget: #{names.length} > #{budget}" if names.length > budget

      names
    end

    def project_hot_skills(project_id, agent_id, runtime_id)
      profile_id = project_profile_id(project_id, agent_id, runtime_id)
      return [] unless profile_id

      hot_skills(profile_id, runtime_id)
    end

    def resolved_hot_skills(project_id, agent_id, runtime_id)
      (global_hot_skills(runtime_id) + project_hot_skills(project_id, agent_id, runtime_id)).uniq.sort
    end

    def eligible_catalog_skills(project_id, agent_id, runtime_id)
      profile_ids = [global_profile_id(runtime_id)]
      project_profile = project_profile_id(project_id, agent_id, runtime_id)
      profile_ids << project_profile if project_profile
      names = profile_ids.compact.flat_map do |profile_id|
        profile = profile_for(profile_id)
        stacks = Array(profile["stacks"]) + Array(profile["catalog_stacks"])
        skills_for_stacks(stacks, runtime_id)
      end
      names.uniq.select { |name| approved_release_for(name, runtime_id) }.sort
    end

    def profile_stack_ids(profile_id, include_catalog: false)
      profile = profile_for(profile_id)
      ids = Array(profile["stacks"])
      ids += Array(profile["catalog_stacks"]) if include_catalog
      ids.uniq
    end

    def approved_release_for(skill_id, runtime_id)
      digest = @current[skill_id]
      return nil unless digest

      release = @releases[[skill_id, digest]]
      return nil unless release

      approval = @approvals.find do |item|
        item.fetch("skill_id") == skill_id && item.fetch("digest") == digest &&
          Array(item["runtimes"]).include?(runtime_id) && item.fetch("decision", "approved").start_with?("approved")
      end
      approval ? release.merge("approval" => approval) : nil
    end

    def snapshot_path(skill_id, runtime_id)
      release = approved_release_for(skill_id, runtime_id)
      raise Error, "Skill #{skill_id} has no digest-bound approval for #{runtime_id}" unless release

      path = expand_path(release.fetch("snapshot_path"))
      raise Error, "Skill Release snapshot is missing: #{skill_id} #{release.fetch('digest')}" unless path.join("SKILL.md").file?

      path
    end

    def projection_path(skill_id, runtime_id)
      release = approved_release_for(skill_id, runtime_id)
      raise Error, "Skill #{skill_id} has no digest-bound approval for #{runtime_id}" unless release

      digest = release.fetch("digest").delete_prefix("sha256:")
      @root.join("skills/.runtime/content", skill_id, digest)
    end

    def ensure_projection(skill_id, runtime_id)
      release = approved_release_for(skill_id, runtime_id)
      raise Error, "Skill #{skill_id} has no digest-bound approval for #{runtime_id}" unless release

      source = snapshot_path(skill_id, runtime_id)
      target = projection_path(skill_id, runtime_id)
      marker = target.join(PROJECTION_MARKER)
      if marker.file?
        data = JSON.parse(marker.read(encoding: "UTF-8"))
        return target if data["digest"] == release.fetch("digest") && projection_skill_files(target) == [target.join("SKILL.md")]
      end

      FileUtils.mkdir_p(target.dirname)
      stage = target.dirname.join(".#{target.basename}.new-#{Process.pid}")
      backup = target.dirname.join(".#{target.basename}.old-#{Process.pid}")
      make_projection_writable(stage) if stage.exist?
      make_projection_writable(backup) if backup.exist?
      FileUtils.rm_rf(stage)
      FileUtils.rm_rf(backup)
      FileUtils.mkdir_p(stage)
      source.children.each { |entry| FileUtils.cp_r(entry, stage, preserve: true) }
      make_projection_writable(stage)
      mappings = rename_nested_skill_files(stage)
      rewrite_projection_links(stage, mappings)
      stage.join(PROJECTION_MARKER).write(
        JSON.pretty_generate(
          "skill_id" => skill_id,
          "digest" => release.fetch("digest"),
          "nested_skill_files_renamed" => mappings.length
        ) + "\n",
        encoding: "UTF-8"
      )
      if target.exist?
        unless target.join(PROJECTION_MARKER).file?
          raise Error, "refusing to replace unmanaged Skill projection: #{target}"
        end
        File.rename(target, backup)
      end
      File.rename(stage, target)
      FileUtils.rm_rf(backup)
      target
    rescue StandardError
      make_projection_writable(stage) if defined?(stage) && stage&.exist?
      FileUtils.rm_rf(stage) if defined?(stage) && stage
      File.rename(backup, target) if defined?(backup) && backup&.exist? && !target.exist?
      raise
    end

    def global_surface_path(runtime_id)
      runtime = @runtimes.fetch(runtime_id) { raise Error, "unknown runtime: #{runtime_id}" }
      expand_path(runtime.fetch("skill_surface").fetch("managed_path"))
    end

    def project_surface_path(project_id, runtime_id)
      @root.join("skills/.runtime/projects", project_id, runtime_id, "skills")
    end

    def project_discovery_root_path(project_id, runtime_id)
      project = @projects.fetch(project_id) { raise Error, "unknown project: #{project_id}" }
      workspace = Pathname.new(project["workspace"] || project.fetch("path")).expand_path.cleanpath
      relative = policy.fetch("project_discovery_roots", {})[runtime_id]
      return nil unless relative

      workspace.join(relative).cleanpath
    end

    def project_overlay_manifest_path(project_id, runtime_id)
      discovery_root = project_discovery_root_path(project_id, runtime_id)
      relative = policy.fetch("project_overlay_manifests", {})[runtime_id]
      return nil unless discovery_root && relative

      discovery_root.join(relative).cleanpath
    end

    def legacy_project_mount_path(project_id, runtime_id)
      project = @projects.fetch(project_id) { raise Error, "unknown project: #{project_id}" }
      workspace = Pathname.new(project["workspace"] || project.fetch("path")).expand_path.cleanpath
      relative = policy.fetch("legacy_project_mounts", {})[runtime_id]
      return nil unless relative

      workspace.join(relative).cleanpath
    end

    def release_source(skill_id, runtime_id, apply: false)
      apply ? ensure_projection(skill_id, runtime_id) : projection_path(skill_id, runtime_id)
    end

    def catalog_index!
      raise Error, "Ruby sqlite3 is unavailable; cannot build the persistent Skill Catalog" unless defined?(SQLite3)

      path = catalog_index_path
      FileUtils.mkdir_p(path.dirname)
      db = SQLite3::Database.new(path.to_s)
      db.execute("DROP TABLE IF EXISTS skill_fts")
      db.execute("DROP TABLE IF EXISTS metadata")
      db.execute("CREATE VIRTUAL TABLE skill_fts USING fts5(skill_id UNINDEXED, digest UNINDEXED, name, category, purpose, description, tags, tokenize='trigram')")
      db.execute("CREATE TABLE metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL)")
      @skills.each_value do |skill|
        next unless skill.fetch("status", nil) == "active"

        digest = @current[skill.fetch("name")]
        release = digest && @releases[[skill.fetch("name"), digest]]
        next unless release

        snapshot = expand_path(release.fetch("snapshot_path"))
        description = skill_description(snapshot.join("SKILL.md"))
        db.execute(
          "INSERT INTO skill_fts(skill_id, digest, name, category, purpose, description, tags) VALUES (?, ?, ?, ?, ?, ?, ?)",
          [skill.fetch("name"), digest, skill.fetch("name"), skill["category"].to_s,
           skill["purpose"].to_s, description.to_s, Array(skill["tags"]).join(" ")]
        )
      end
      db.execute("INSERT INTO metadata(key, value) VALUES ('fingerprint', ?)", [catalog_fingerprint])
      db.close
      path
    end

    def catalog_search(query, project_id:, agent_id:, runtime_id:, top_k: nil)
      query = query.to_s.strip
      raise Error, "Skill Catalog search requires a query" if query.empty?

      eligible = eligible_catalog_skills(project_id, agent_id, runtime_id).to_set
      limit = Integer(top_k || policy.fetch("default_search_top_k"))
      maximum = Integer(policy.fetch("max_search_top_k"))
      raise Error, "top_k must be between 1 and #{maximum}" unless limit.between?(1, maximum)

      rows = sqlite_search(query).select { |item| eligible.include?(item.fetch("skill_id")) }
      ranked = fallback_search(query, eligible.to_a)
      combined = (rows + ranked).uniq { |item| item.fetch("skill_id") }.first(limit)
      hot = resolved_hot_skills(project_id, agent_id, runtime_id).to_set
      results = combined.map do |item|
        skill = @skills.fetch(item.fetch("skill_id"))
        {
          "skill_id" => item.fetch("skill_id"),
          "digest" => @current.fetch(item.fetch("skill_id")),
          "category" => skill["category"],
          "purpose" => skill["purpose"],
          "hot" => hot.include?(item.fetch("skill_id")),
          "score_source" => item.fetch("score_source")
        }
      end
      log_catalog_event("search", project_id, runtime_id, query, results.map { |item| item.fetch("skill_id") })
      results
    end

    def catalog_load(skill_id, project_id:, agent_id:, runtime_id:, digest: nil)
      ensure_catalog_access!(skill_id, project_id, agent_id, runtime_id)
      release = approved_release_for(skill_id, runtime_id)
      requested = digest || release.fetch("digest")
      raise Error, "requested digest is not the current approved Release for #{skill_id}" unless requested == release.fetch("digest")

      content = read_bounded_file(snapshot_path(skill_id, runtime_id).join("SKILL.md"))
      result = {
        "skill_id" => skill_id,
        "digest" => requested,
        "content" => content,
        "scripts_authorized" => false
      }
      log_catalog_event("load", project_id, runtime_id, skill_id, [skill_id])
      result
    end

    def catalog_read(skill_id, resource, project_id:, agent_id:, runtime_id:, digest: nil)
      ensure_catalog_access!(skill_id, project_id, agent_id, runtime_id)
      release = approved_release_for(skill_id, runtime_id)
      requested = digest || release.fetch("digest")
      raise Error, "requested digest is not the current approved Release for #{skill_id}" unless requested == release.fetch("digest")

      relative = Pathname.new(resource.to_s)
      raise Error, "resource path must be relative" if relative.absolute?
      raise Error, "resource path escapes the Skill Release" if relative.each_filename.any? { |part| part == ".." }

      snapshot = snapshot_path(skill_id, runtime_id).realpath
      path = snapshot.join(relative).cleanpath
      raise Error, "resource does not exist: #{resource}" unless path.file?
      resolved = path.realpath
      prefix = "#{snapshot}#{File::SEPARATOR}"
      raise Error, "resource symlink escapes the Skill Release" unless resolved.to_s.start_with?(prefix)

      result = {
        "skill_id" => skill_id,
        "digest" => requested,
        "path" => relative.to_s,
        "content" => read_bounded_file(resolved),
        "scripts_authorized" => false
      }
      log_catalog_event("read", project_id, runtime_id, "#{skill_id}:#{relative}", [skill_id])
      result
    end

    def visibility_budget(project_id, agent_id, runtime_id)
      managed = resolved_hot_skills(project_id, agent_id, runtime_id).map { |name| skill_metadata_record(name, "managed") }
      runtime_builtin = runtime_builtin_skill_records(runtime_id)
      user_global = user_global_skill_records(runtime_id)
      native = project_native_skill_records(project_id, agent_id, runtime_id)
      plugins = runtime_id == "codex" ? enabled_codex_plugin_skill_records : []
      plugin_packages = runtime_id == "codex" ? codex_plugin_inventory.select { |item| item.fetch("enabled") } : []
      records = (managed + runtime_builtin + user_global + native + plugins)
                .uniq { |item| [item.fetch("source"), item.fetch("name")] }
      result = {
        "project" => project_id,
        "runtime" => runtime_id,
        "managed" => managed.length,
        "runtime_builtin" => runtime_builtin.length,
        "user_global" => user_global.length,
        "project_native" => native.length,
        "plugin" => plugins.length,
        "plugin_packages" => plugin_packages.map { |item| item.fetch("selector") }.sort,
        "total" => records.length,
        "description_characters" => records.sum { |item| item.fetch("name").length + item.fetch("description", "").length },
        "max_total" => Integer(policy.fetch("max_visible_descriptions")),
        "max_description_characters" => Integer(policy.fetch("max_description_characters"))
      }
      result["within_budget"] = result.fetch("total") <= result.fetch("max_total") &&
                                result.fetch("description_characters") <= result.fetch("max_description_characters")
      result
    end

    def validate
      errors = []
      warnings = []
      used = Set.new
      @stacks.each do |stack_id, stack|
        Array(stack["skills"]).each do |skill_id|
          errors << "#{stack_id} references unknown Skill: #{skill_id}" unless @skills.key?(skill_id)
          used << skill_id
        end
        compatibility = stack.fetch("compatibility", {})
        @runtimes.each_key do |runtime_id|
          state = compatibility[runtime_id]
          errors << "#{stack_id} has no compatibility for #{runtime_id}" unless state
          if state && !%w[native compatible needs-review denied].include?(state)
            errors << "#{stack_id} has invalid compatibility for #{runtime_id}: #{state}"
          end
        end
      end

      active = @skills.values.select { |item| item["status"] == "active" }.map { |item| item.fetch("name") }
      unassigned = active - used.to_a
      warnings << "active Skills not assigned to a v2 Stack: #{unassigned.join(', ')}" unless unassigned.empty?

      @profiles.each do |profile_id, profile|
        (Array(profile["stacks"]) + Array(profile["catalog_stacks"])).uniq.each do |stack_id|
          errors << "profile #{profile_id} references unknown Stack: #{stack_id}" unless @stacks.key?(stack_id)
        end
      end

      @bindings.each do |binding|
        project_id = binding.fetch("project")
        agent_id = binding.fetch("agent")
        runtime_id = binding.fetch("runtime")
        profile_id = binding.fetch("profile")
        errors << "binding references unknown project: #{project_id}" unless @projects.key?(project_id)
        errors << "binding references unknown agent: #{agent_id}" unless @agents.key?(agent_id)
        errors << "binding references unknown runtime: #{runtime_id}" unless @runtimes.key?(runtime_id)
        errors << "binding references unknown profile: #{profile_id}" unless @profiles.key?(profile_id)
        next unless @projects.key?(project_id) && @runtimes.key?(runtime_id) && @profiles.key?(profile_id)

        allowed = Array(@projects.fetch(project_id)["allowed_runtimes"])
        errors << "project #{project_id} does not allow bound runtime #{runtime_id}" unless allowed.empty? || allowed.include?(runtime_id)
        begin
          resolved_hot_skills(project_id, agent_id, runtime_id).each do |skill_id|
            errors << "#{project_id}/#{runtime_id} has no approved Release for #{skill_id}" unless approved_release_for(skill_id, runtime_id)
          end
          budget = visibility_budget(project_id, agent_id, runtime_id)
          if budget.fetch("total") > budget.fetch("max_total")
            warnings << "#{project_id}/#{runtime_id} visible Skill budget exceeded: #{budget.fetch('total')} > #{budget.fetch('max_total')}"
          end
          if budget.fetch("description_characters") > budget.fetch("max_description_characters")
            warnings << "#{project_id}/#{runtime_id} description budget exceeded: #{budget.fetch('description_characters')} > #{budget.fetch('max_description_characters')}"
          end
        rescue Error => error
          errors << error.message
        end
      end

      @runtimes.each_key do |runtime_id|
        profile_id = policy.fetch("global_profiles", {})[runtime_id]
        errors << "runtime #{runtime_id} has no global profile" unless profile_id
        errors << "runtime #{runtime_id} references unknown global profile: #{profile_id}" if profile_id && !@profiles.key?(profile_id)
      end

      plugin_policy = policy.fetch("codex_plugins", {})
      unless plugin_policy.empty?
        inventory = codex_plugin_inventory
        enabled = inventory.select { |item| item.fetch("enabled") }.map { |item| item.fetch("selector") }
        baseline = Array(plugin_policy["baseline_enabled"])
        on_demand = Array(plugin_policy["optional_on_demand"])
        missing = baseline - enabled
        optional_enabled = on_demand & enabled
        unmanaged = enabled - baseline - on_demand
        warnings << "baseline Codex plugins not enabled: #{missing.join(', ')}" unless missing.empty?
        warnings << "on-demand Codex plugins currently enabled: #{optional_enabled.join(', ')}" unless optional_enabled.empty?
        warnings << "enabled Codex plugins not assigned to a plugin policy: #{unmanaged.join(', ')}" unless unmanaged.empty?
      end

      active.each do |skill_id|
        digest = @current[skill_id]
        errors << "active Skill has no current Release: #{skill_id}" unless digest
        next unless digest

        release = @releases[[skill_id, digest]]
        errors << "current Release record missing: #{skill_id} #{digest}" unless release
        if release
          snapshot = expand_path(release.fetch("snapshot_path"))
          errors << "current Release snapshot missing: #{skill_id} #{digest}" unless snapshot.join("SKILL.md").file?
        end
      end

      [errors.uniq, warnings.uniq]
    end

    private

    def policy
      @profile_data.fetch("policy")
    end

    def profile_for(profile_id)
      @profiles.fetch(profile_id) { raise Error, "unknown Skill profile: #{profile_id}" }
    end

    def skills_for_stacks(stack_ids, runtime_id)
      stack_ids.flat_map do |stack_id|
        stack = @stacks.fetch(stack_id) { raise Error, "unknown Skill Stack: #{stack_id}" }
        state = stack.fetch("compatibility", {}).fetch(runtime_id, "needs-review")
        EXPOSED_COMPATIBILITY.include?(state) ? Array(stack["skills"]) : []
      end.uniq.sort
    end

    def load_yaml(path)
      full = expand_path(path)
      raise Error, "registry missing: #{full}" unless full.file?

      data = YAML.safe_load(full.read(encoding: "UTF-8"), permitted_classes: [Date, Time], aliases: false)
      raise Error, "registry is not a mapping: #{full}" unless data.is_a?(Hash)

      data
    rescue Psych::Exception => error
      raise Error, "invalid YAML #{full}: #{error.message}"
    end

    def load_json(path)
      full = expand_path(path)
      raise Error, "registry missing: #{full}" unless full.file?

      data = JSON.parse(full.read(encoding: "UTF-8"))
      raise Error, "registry is not a mapping: #{full}" unless data.is_a?(Hash)

      data
    rescue JSON::ParserError => error
      raise Error, "invalid JSON #{full}: #{error.message}"
    end

    def expand_path(path)
      value = Pathname.new(path.to_s)
      value = @root.join(value) unless value.absolute?
      value.expand_path.cleanpath
    end

    def index_by(items, key)
      Array(items).each_with_object({}) do |item, index|
        value = item.fetch(key)
        raise Error, "duplicate #{key}: #{value}" if index.key?(value)

        index[value] = item
      end
    end

    def projection_skill_files(root)
      Dir.glob(root.join("**/SKILL.md").to_s, File::FNM_DOTMATCH).map { |item| Pathname.new(item) }.sort
    end

    def make_projection_writable(root)
      Find.find(root.to_s) do |entry|
        path = Pathname.new(entry)
        next if path.symlink?

        path.chmod(path.stat.mode | 0o200)
      end
    end

    def rename_nested_skill_files(root)
      projection_skill_files(root).each_with_object({}) do |path, mappings|
        next if path == root.join("SKILL.md")

        replacement = path.dirname.join("SKILL.resource.md")
        original_relative = path.relative_path_from(root).to_s
        replacement_relative = replacement.relative_path_from(root).to_s
        File.rename(path, replacement)
        mappings[original_relative] = replacement_relative
      end
    end

    def rewrite_projection_links(root, mappings)
      return if mappings.empty?

      Find.find(root.to_s) do |entry|
        path = Pathname.new(entry)
        next unless path.file? && TEXT_EXTENSIONS.include?(path.extname.downcase)

        text = path.read(encoding: "UTF-8", invalid: :replace, undef: :replace)
        updated = text.dup
        mappings.each do |original, replacement|
          updated = updated.gsub(original, replacement)
          file_relative_dir = path.dirname.relative_path_from(root)
          original_relative = Pathname.new(original).relative_path_from(file_relative_dir).to_s
          replacement_relative = Pathname.new(replacement).relative_path_from(file_relative_dir).to_s
          updated = updated.gsub(original_relative, replacement_relative)
        rescue ArgumentError
          next
        end
        path.write(updated, encoding: "UTF-8") if updated != text
      end
    end

    def catalog_index_path
      @root.join("skills/contexts/skill-catalog/catalog.sqlite3")
    end

    def catalog_fingerprint
      digest = Digest::SHA256.new
      [@profile_registry_path, @release_registry_path, @skill_registry_path].each do |path|
        digest.update(path.read(encoding: "UTF-8"))
      end
      digest.hexdigest
    end

    def ensure_catalog_index
      return nil unless defined?(SQLite3)

      path = catalog_index_path
      return catalog_index! unless path.file?

      db = SQLite3::Database.new(path.to_s)
      fingerprint = db.get_first_value("SELECT value FROM metadata WHERE key='fingerprint'")
      db.close
      fingerprint == catalog_fingerprint ? path : catalog_index!
    rescue SQLite3::Exception
      catalog_index!
    end

    def sqlite_search(query)
      path = ensure_catalog_index
      return [] unless path
      return [] if query.each_char.count < 3

      db = SQLite3::Database.new(path.to_s)
      db.results_as_hash = true
      phrase = %("#{query.gsub('"', '""')}")
      rows = db.execute(
        "SELECT skill_id, digest, bm25(skill_fts) AS rank FROM skill_fts WHERE skill_fts MATCH ? ORDER BY rank LIMIT 200",
        [phrase]
      )
      db.close
      rows.map { |row| { "skill_id" => row.fetch("skill_id"), "score_source" => "fts5-bm25" } }
    rescue SQLite3::Exception
      []
    end

    def fallback_search(query, eligible)
      needle = query.downcase
      expanded_needle = ([needle] + policy.fetch("search_aliases", {}).each_with_object([]) do |(source, expansion), aliases|
        aliases << expansion.to_s.downcase if needle.include?(source.to_s.downcase)
      end).join(" ")
      eligible.each_with_object([]) do |skill_id, matches|
        skill = @skills.fetch(skill_id)
        description = begin
          release = @releases[[skill_id, @current[skill_id]]]
          release ? skill_description(expand_path(release.fetch("snapshot_path")).join("SKILL.md")) : ""
        rescue StandardError
          ""
        end
        fields = [skill_id, skill["category"], skill["purpose"], description, *Array(skill["tags"])].compact
        haystack = fields.join(" ").downcase
        score = if skill_id.downcase == needle
                  1000
                elsif skill_id.downcase.include?(needle)
                  800
                elsif haystack.include?(needle)
                  500
                else
                  query_tokens = expanded_needle.scan(/[[:alnum:]\p{Han}]+/)
                  query_tokens.sum { |token| haystack.include?(token) ? token.length : 0 }
                end
        next if score.zero?

        matches << { "skill_id" => skill_id, "score" => score, "score_source" => "deterministic-fallback" }
      end.sort_by { |item| [-item.fetch("score"), item.fetch("skill_id")] }
    end

    def skill_description(path)
      return "" unless path.file?

      head = path.read(encoding: "UTF-8", invalid: :replace, undef: :replace).lines.first(120).join
      match = head.match(/\A---\s*\n(.*?)\n---\s*\n/m)
      return "" unless match

      data = YAML.safe_load(match[1], permitted_classes: [], aliases: false)
      data.is_a?(Hash) ? data.fetch("description", "").to_s : ""
    rescue StandardError
      ""
    end

    def skill_metadata_record(name, source)
      skill = @skills.fetch(name)
      release = @releases[[name, @current[name]]]
      description = release ? skill_description(expand_path(release.fetch("snapshot_path")).join("SKILL.md")) : ""
      { "name" => name, "description" => description, "source" => source }
    end

    def runtime_builtin_skill_records(runtime_id)
      runtime = @runtimes.fetch(runtime_id)
      Array(runtime["discovery_roots"])
        .select { |item| item["budget_class"] == "runtime_builtin" }
        .flat_map { |item| find_skill_records(expand_path(item.fetch("path")), "runtime-builtin") }
        .uniq { |item| [item.fetch("source"), item.fetch("name")] }
    end

    def user_global_skill_records(runtime_id)
      runtime = @runtimes.fetch(runtime_id)
      managed_names = global_hot_skills(runtime_id).to_set
      Array(runtime["discovery_roots"])
        .select { |item| item["budget_class"] == "user_global" }
        .flat_map { |item| find_skill_records(expand_path(item.fetch("path")), "user-global") }
        .reject { |item| managed_names.include?(item.fetch("name")) }
        .uniq { |item| [item.fetch("source"), item.fetch("name")] }
    end

    def project_native_skill_records(project_id, agent_id, runtime_id)
      project = @projects.fetch(project_id)
      workspace = Pathname.new(project["workspace"] || project.fetch("path")).expand_path.cleanpath
      root_relative = policy.fetch("project_discovery_roots", {})[runtime_id]
      return [] unless root_relative

      discovery_root = workspace.join(root_relative)
      return [] unless discovery_root.directory?

      managed_roots = project_hot_skills(project_id, agent_id, runtime_id).map { |name| discovery_root.join(name) }
      legacy_mount = legacy_project_mount_path(project_id, runtime_id)
      managed_roots << legacy_mount if legacy_mount
      find_skill_records(discovery_root, "project-native", exclude_roots: managed_roots)
    end

    def enabled_codex_plugin_skill_records
      roots = codex_plugin_inventory.select { |item| item.fetch("enabled") }
                                    .map { |item| item.fetch("path") }
      roots.flat_map { |path| find_skill_records(path, "codex-plugin") }
           .uniq { |item| [item.fetch("source"), item.fetch("name")] }
    rescue StandardError
      []
    end

    def codex_plugin_inventory
      executable = @runtimes.dig("codex", "executable", "command") || "codex"
      stdout, _stderr, status = Open3.capture3(executable, "plugin", "list")
      return [] unless status.success?

      begin
        parsed = JSON.parse(stdout)
        if parsed.is_a?(Hash) && parsed["installed"].is_a?(Array)
          return parsed.fetch("installed").each_with_object([]) do |entry, rows|
            next unless entry.is_a?(Hash) && entry["pluginId"]

            source = entry.dig("source", "path") || entry["installedPath"]
            next unless source

            rows << {
              "selector" => entry.fetch("pluginId"),
              "enabled" => entry["enabled"] == true,
              "installed" => entry["installed"] == true,
              "path" => Pathname.new(source).expand_path.cleanpath
            }
          end
        end
      rescue JSON::ParserError
        # Older Codex versions expose a human-readable table.
      end

      stdout.lines.each_with_object([]) do |line, rows|
        columns = line.strip.split(/\s{2,}/)
        next unless columns.length >= 3
        next unless columns[1].start_with?("installed") || columns[1] == "not installed"

        path = Pathname.new(columns.last).expand_path.cleanpath
        rows << {
          "selector" => columns.first,
          "enabled" => columns[1] == "installed, enabled",
          "installed" => columns[1].start_with?("installed"),
          "path" => path
        }
      end
    rescue StandardError
      []
    end

    def find_skill_records(root, source, exclude_root: nil, exclude_roots: [])
      records = []
      excluded = [exclude_root, *exclude_roots].compact.map { |item| Pathname.new(item).expand_path.cleanpath }
      Find.find(root.to_s) do |entry|
        path = Pathname.new(entry)
        if excluded.any? { |item| path == item || path.to_s.start_with?("#{item}#{File::SEPARATOR}") }
          Find.prune if path.directory?
          next
        end
        if path.symlink? && path.directory?
          skill_md = path.join("SKILL.md")
          if skill_md.file?
            metadata = skill_description_and_name(skill_md)
            records << { "name" => metadata.fetch("name"), "description" => metadata.fetch("description"), "source" => source }
          end
          Find.prune
          next
        end
        if path.directory? && %w[.git node_modules __pycache__].include?(path.basename.to_s)
          Find.prune
          next
        end
        next unless path.basename.to_s == "SKILL.md" && path.file?

        metadata = skill_description_and_name(path)
        records << { "name" => metadata.fetch("name"), "description" => metadata.fetch("description"), "source" => source }
      end
      records
    rescue Errno::ENOENT, Errno::EACCES, Errno::EPERM
      []
    end

    def skill_description_and_name(path)
      head = path.read(encoding: "UTF-8", invalid: :replace, undef: :replace).lines.first(120).join
      match = head.match(/\A---\s*\n(.*?)\n---\s*\n/m)
      data = match ? YAML.safe_load(match[1], permitted_classes: [], aliases: false) : {}
      data = {} unless data.is_a?(Hash)
      {
        "name" => data.fetch("name", path.dirname.basename.to_s).to_s,
        "description" => data.fetch("description", "").to_s
      }
    rescue StandardError
      { "name" => path.dirname.basename.to_s, "description" => "" }
    end

    def ensure_catalog_access!(skill_id, project_id, agent_id, runtime_id)
      eligible = eligible_catalog_skills(project_id, agent_id, runtime_id)
      raise Error, "Skill #{skill_id} is not allowed by the selected project Profile" unless eligible.include?(skill_id)
    end

    def read_bounded_file(path)
      maximum = Integer(policy.fetch("max_resource_bytes", 1_048_576))
      raise Error, "resource exceeds #{maximum} bytes" if path.size > maximum

      path.read(encoding: "UTF-8", invalid: :replace, undef: :replace)
    end

    def log_catalog_event(action, project_id, runtime_id, subject, matches)
      path = @root.join("skills/logs/skill-catalog/events.jsonl")
      FileUtils.mkdir_p(path.dirname)
      event = {
        "time" => Time.now.utc.iso8601,
        "action" => action,
        "project" => project_id,
        "runtime" => runtime_id,
        "subject_sha256" => Digest::SHA256.hexdigest(subject.to_s),
        "matches" => matches
      }
      File.open(path, "a", encoding: "UTF-8") { |file| file.puts(JSON.generate(event)) }
    rescue StandardError
      nil
    end
  end
end
