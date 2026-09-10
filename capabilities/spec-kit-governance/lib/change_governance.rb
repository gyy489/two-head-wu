# frozen_string_literal: true

require "date"
require "json"
require "open3"
require "pathname"
require "set"
require "time"
require "yaml"

module TwoHeadWu
  class ChangeGovernanceError < StandardError; end

  class ChangeGovernance
    GIT_ISOLATION_ENV = {
      "GIT_DIR" => nil,
      "GIT_WORK_TREE" => nil,
      "GIT_COMMON_DIR" => nil,
      "GIT_INDEX_FILE" => nil
    }.freeze
    ACTIVE_STATUSES = %w[in-progress review].freeze
    STATUSES = (ACTIVE_STATUSES + %w[planned completed cancelled]).freeze
    REQUIRED_KEYS = %w[
      schema_version id status goal spec plan tasks affected_modules writable_paths forbidden_paths
      invariants dependencies implementation_order acceptance_commands documentation_impact migration
      rollback delivery review
    ].freeze
    REVIEW_INPUTS = %w[
      spec plan change-capsule diff test-evidence migration-evidence rollback-evidence
    ].freeze
    MAX_FILES_WITHOUT_SPEC = 10
    MAX_EFFECTIVE_LINES_PER_COMMIT = 800
    DOCUMENTATION_PATHS = %r{
      \A(?:
        AGENTS\.md|PROJECT_MAP\.md|README\.md|.*\.md|
        catalog/|registries/|mcp/|skills/registries/|skills/\.runtime/|
        \.agents/|\.claude/
      )
    }x.freeze

    attr_reader :root

    def initialize(root)
      @root = Pathname.new(root).expand_path.cleanpath
    end

    def validate_all!
      errors = []
      capsules = capsule_paths.map do |capsule_path|
        data = load_capsule(capsule_path, errors)
        validate_capsule(capsule_path, data, errors) if data
        [capsule_path, data]
      end
      active = capsules.select { |_path, data| data && ACTIVE_STATUSES.include?(data["status"]) }
      if active.length > 1
        selected = selected_capsule_path(errors)
        selected_active = active.find { |path, _data| selected && path == selected }
        if selected_active
          active = [selected_active]
        else
          errors << "worktree has more than one active Change Capsule and no active .specify/feature.json selection: #{active.map { |path, _| relative(path) }.join(', ')}"
        end
      end
      fail_with!(errors)
      { "capsules" => capsules.length, "active" => active.map { |path, data| capsule_summary(path, data) } }
    end

    def validate_one!(relative_path)
      errors = []
      capsule_path = confined_path(relative_path, errors, "change capsule")
      data = capsule_path && load_capsule(capsule_path, errors)
      validate_capsule(capsule_path, data, errors) if capsule_path && data
      fail_with!(errors)
      capsule_summary(capsule_path, data)
    end

    def gate!(scope)
      unless %w[staged worktree].include?(scope)
        raise ChangeGovernanceError, "scope must be staged or worktree"
      end

      state = validate_all!
      changed = changed_paths(scope)
      line_count = effective_line_count(scope)
      package_ids = changed_capability_packages(changed)
      active = state.fetch("active")
      errors = []

      if active.empty?
        errors << "#{changed.length} changed files require Spec, Plan, and Change Capsule (limit #{MAX_FILES_WITHOUT_SPEC})" if changed.length > MAX_FILES_WITHOUT_SPEC
        errors << "#{line_count} effective changed lines must be split (limit #{MAX_EFFECTIVE_LINES_PER_COMMIT})" if line_count > MAX_EFFECTIVE_LINES_PER_COMMIT
        if package_ids.length > 1
          errors << "cross-capability change requires a Change Capsule with dependencies and implementation order: #{package_ids.join(', ')}"
        end
      elsif changed.any?
        capsule_path = root.join(active.first.fetch("path"))
        capsule = load_yaml(capsule_path)
        enforce_staged_capsule_snapshot(capsule_path, capsule, errors) if scope == "staged"
        enforce_scope(capsule, changed, errors)
        enforce_change_shape(capsule, changed, line_count, package_ids, errors)
      end

      fail_with!(errors)
      {
        "scope" => scope,
        "changed_files" => changed.length,
        "effective_lines" => line_count,
        "capability_packages" => package_ids,
        "active_change" => active.first
      }
    end

    def status
      validate_all!
    end

    private

    def capsule_paths
      Dir.glob(root.join("specs/*/change.yaml").to_s).sort.map { |item| Pathname.new(item) }
    end

    def selected_capsule_path(errors)
      selector = root.join(".specify/feature.json")
      return nil unless selector.file? && !selector.symlink?

      payload = JSON.parse(selector.read(encoding: "UTF-8"))
      directory = payload["feature_directory"]
      unless directory.is_a?(String) && directory.match?(%r{\Aspecs/[A-Za-z0-9._-]+\z})
        errors << ".specify/feature.json: feature_directory is invalid"
        return nil
      end
      selected = root.join(directory, "change.yaml").cleanpath
      prefix = "#{root.join('specs').cleanpath}#{File::SEPARATOR}"
      unless selected.to_s.start_with?(prefix) && selected.file?
        errors << ".specify/feature.json: selected Change Capsule is unavailable"
        return nil
      end
      selected
    rescue JSON::ParserError => error
      errors << ".specify/feature.json: invalid JSON: #{error.message}"
      nil
    end

    def load_capsule(capsule_path, errors)
      load_yaml(capsule_path)
    rescue ChangeGovernanceError => error
      errors << "#{relative(capsule_path)}: #{error.message}"
      nil
    end

    def load_yaml(file)
      raise ChangeGovernanceError, "file is missing" unless file.file?

      data = YAML.safe_load(
        file.read(encoding: "UTF-8"),
        permitted_classes: [Date, Time],
        aliases: false
      )
      raise ChangeGovernanceError, "YAML root is not a mapping" unless data.is_a?(Hash)

      data
    rescue Psych::Exception => error
      raise ChangeGovernanceError, "invalid YAML: #{error.message}"
    end

    def validate_capsule(capsule_path, data, errors)
      label = relative(capsule_path)
      REQUIRED_KEYS.each { |key| errors << "#{label}: missing #{key}" unless data.key?(key) }
      return unless (REQUIRED_KEYS - data.keys).empty?

      errors << "#{label}: schema_version must be 1" unless data["schema_version"] == 1
      errors << "#{label}: invalid id" unless data["id"].to_s.match?(/\A[0-9]{3}-[a-z0-9]+(?:-[a-z0-9]+)*\z/)
      errors << "#{label}: invalid status #{data['status']}" unless STATUSES.include?(data["status"])
      errors << "#{label}: goal must not be empty" if data["goal"].to_s.strip.empty?

      %w[spec plan tasks].each do |key|
        validate_file_reference(label, key, data[key], errors)
      end

      %w[affected_modules writable_paths invariants acceptance_commands implementation_order].each do |key|
        value = data[key]
        errors << "#{label}: #{key} must be a non-empty array" unless value.is_a?(Array) && !value.empty?
      end
      errors << "#{label}: forbidden_paths must be an array" unless data["forbidden_paths"].is_a?(Array)
      errors << "#{label}: dependencies must be an array" unless data["dependencies"].is_a?(Array)

      validate_path_patterns(label, data, errors)
      validate_affected_modules(label, data, errors)
      validate_documentation_impact(label, data, errors)
      validate_delivery(label, data, errors)
      validate_review(label, data, errors)
      errors << "#{label}: migration must be a mapping" unless data["migration"].is_a?(Hash)
      errors << "#{label}: rollback must be a mapping" unless data["rollback"].is_a?(Hash)
    end

    def validate_file_reference(label, key, value, errors)
      candidate = confined_path(value, errors, "#{label}: #{key}")
      errors << "#{label}: #{key} file missing: #{value}" if candidate && !candidate.file?
    end

    def validate_path_patterns(label, data, errors)
      %w[writable_paths forbidden_paths].each do |key|
        next unless data[key].is_a?(Array)

        data[key].each do |pattern|
          unless valid_relative_pattern?(pattern)
            errors << "#{label}: invalid #{key} entry: #{pattern.inspect}"
          end
        end
      end
    end

    def validate_affected_modules(label, data, errors)
      modules = Array(data["affected_modules"])
      known_modules = navigation_module_ids | capability_package_ids
      unknown = modules.reject { |item| known_modules.include?(item) }
      if ACTIVE_STATUSES.include?(data["status"]) || data["status"] == "planned"
        errors << "#{label}: unknown affected_modules: #{unknown.join(', ')}" unless unknown.empty?
      end

      affected_packages = modules.select { |item| capability_package_ids.include?(item) }
      return unless affected_packages.length > 1

      dependencies = Array(data["dependencies"])
      if dependencies.empty?
        errors << "#{label}: cross-capability change must declare dependencies"
      else
        dependencies.each do |dependency|
          unless dependency.is_a?(Hash) && %w[from to purpose].all? { |key| !dependency[key].to_s.strip.empty? }
            errors << "#{label}: every dependency requires from, to, and purpose"
            next
          end
          %w[from to].each do |key|
            unless modules.include?(dependency[key])
              errors << "#{label}: dependency #{key} is not an affected module: #{dependency[key]}"
            end
          end
        end
      end

      missing_order = affected_packages - Array(data["implementation_order"])
      unless missing_order.empty?
        errors << "#{label}: implementation_order missing capability packages: #{missing_order.join(', ')}"
      end
    end

    def validate_documentation_impact(label, data, errors)
      impact = data["documentation_impact"]
      unless impact.is_a?(Hash)
        errors << "#{label}: documentation_impact must be a mapping"
        return
      end
      %w[required modules update_command].each do |key|
        errors << "#{label}: documentation_impact missing #{key}" unless impact.key?(key)
      end
      if impact["required"] == true && impact["update_command"].to_s !~ /wu\s+更新说明/
        errors << "#{label}: documentation update command must run wu 更新说明"
      end
    end

    def validate_delivery(label, data, errors)
      delivery = data["delivery"]
      unless delivery.is_a?(Hash)
        errors << "#{label}: delivery must be a mapping"
        return
      end
      unless delivery["max_files_without_spec"] == MAX_FILES_WITHOUT_SPEC
        errors << "#{label}: max_files_without_spec must be #{MAX_FILES_WITHOUT_SPEC}"
      end
      unless delivery["max_effective_lines_per_commit"] == MAX_EFFECTIVE_LINES_PER_COMMIT
        errors << "#{label}: max_effective_lines_per_commit must be #{MAX_EFFECTIVE_LINES_PER_COMMIT}"
      end
      commits = delivery["commits"]
      errors << "#{label}: delivery commits must be a non-empty array" unless commits.is_a?(Array) && !commits.empty?
    end

    def validate_review(label, data, errors)
      review = data["review"]
      unless review.is_a?(Hash)
        errors << "#{label}: review must be a mapping"
        return
      end
      errors << "#{label}: review mode must be fresh-context" unless review["mode"] == "fresh-context"
      errors << "#{label}: original_chat_shared must be false" unless review["original_chat_shared"] == false
      missing = REVIEW_INPUTS - Array(review["shared_inputs"])
      errors << "#{label}: review shared_inputs missing: #{missing.join(', ')}" unless missing.empty?
    end

    def enforce_scope(capsule, changed, errors)
      writable = Array(capsule["writable_paths"])
      forbidden = Array(capsule["forbidden_paths"])
      changed.each do |relative_path|
        if forbidden.any? { |pattern| path_match?(pattern, relative_path) }
          errors << "forbidden path changed: #{relative_path}"
        elsif !writable.any? { |pattern| path_match?(pattern, relative_path) }
          errors << "path is outside writable_paths: #{relative_path}"
        end
      end
    end

    def enforce_staged_capsule_snapshot(capsule_path, capsule, errors)
      evidence_paths = [relative(capsule_path), *%w[spec plan tasks].map { |key| capsule[key] }]
      evidence_paths.each do |relative_path|
        next unless relative_path.is_a?(String)

        unless indexed_path?(relative_path)
          errors << "staged gate requires tracked or staged governance evidence: #{relative_path}"
          next
        end
        unstaged = git_capture("diff", "--name-only", "--", relative_path)
        unless unstaged.empty?
          errors << "staged gate refuses unstaged governance evidence changes: #{relative_path}"
        end
      end
    end

    def enforce_change_shape(capsule, changed, line_count, changed_packages, errors)
      if line_count > MAX_EFFECTIVE_LINES_PER_COMMIT
        errors << "#{line_count} effective changed lines exceed #{MAX_EFFECTIVE_LINES_PER_COMMIT}; split the staged commit"
      end

      affected = Array(capsule["affected_modules"])
      undeclared_packages = changed_packages - affected
      unless undeclared_packages.empty?
        errors << "changed capability packages are absent from affected_modules: #{undeclared_packages.join(', ')}"
      end

      if changed_packages.length > 1
        errors << "cross-capability staged change has no declared dependencies" if Array(capsule["dependencies"]).empty?
        missing_order = changed_packages - Array(capsule["implementation_order"])
        errors << "implementation_order misses staged capability packages: #{missing_order.join(', ')}" unless missing_order.empty?
      end

      if changed.any? { |item| item.match?(DOCUMENTATION_PATHS) }
        impact = capsule["documentation_impact"]
        unless impact.is_a?(Hash) && impact["required"] == true
          errors << "documentation, Catalog, registry, or runtime-surface change must declare documentation_impact.required"
        end
      end
    end

    def changed_paths(scope)
      if scope == "staged"
        stdout = git_capture("diff", "--cached", "--name-only", "--diff-filter=ACMRD", "-z")
        stdout.split("\0").reject(&:empty?).uniq
      else
        stdout = git_capture("status", "--porcelain=v1", "-z", "--untracked-files=all")
        parse_porcelain_paths(stdout)
      end
    end

    def effective_line_count(scope)
      arguments = scope == "staged" ? ["diff", "--cached", "--numstat"] : ["diff", "HEAD", "--numstat"]
      total = git_capture(*arguments).each_line.sum do |line|
        added, deleted, = line.split("\t", 3)
        numeric_change(added) + numeric_change(deleted)
      end
      return total if scope == "staged"

      untracked = changed_paths("worktree").select { |item| !tracked_path?(item) }
      total + untracked.sum { |item| count_file_lines(root.join(item)) }
    end

    def numeric_change(value)
      value == "-" ? 1 : value.to_i
    end

    def tracked_path?(relative_path)
      _stdout, _stderr, status = Open3.capture3(
        GIT_ISOLATION_ENV, "git", "ls-files", "--error-unmatch", "--", relative_path,
        chdir: root.to_s
      )
      status.success?
    end

    def indexed_path?(relative_path)
      _stdout, _stderr, status = Open3.capture3(
        GIT_ISOLATION_ENV, "git", "ls-files", "--cached", "--error-unmatch", "--", relative_path,
        chdir: root.to_s
      )
      status.success?
    end

    def count_file_lines(file)
      return 0 unless file.file?
      return 1 if file.size > 5 * 1024 * 1024

      file.each_line.count
    rescue ArgumentError
      1
    end

    def changed_capability_packages(changed)
      changed.each_with_object([]) do |item, packages|
        match = item.match(%r{\Acapabilities/([^/]+)/})
        packages << match[1] if match
      end.uniq.sort
    end

    def parse_porcelain_paths(stdout)
      entries = stdout.split("\0")
      paths = []
      index = 0
      while index < entries.length
        entry = entries[index]
        status_code = entry[0, 2]
        paths << entry[3..] if entry.length > 3
        if status_code && status_code.match?(/[RC]/)
          index += 1
          paths << entries[index] if entries[index]
        end
        index += 1
      end
      paths.compact.uniq
    end

    def git_capture(*arguments)
      stdout, stderr, status = Open3.capture3(GIT_ISOLATION_ENV, "git", *arguments, chdir: root.to_s)
      raise ChangeGovernanceError, "git #{arguments.join(' ')} failed: #{stderr.strip}" unless status.success?

      stdout
    end

    def navigation_module_ids
      registry = load_yaml(root.join("catalog/documentation_registry.yaml"))
      Array(registry["modules"]).map { |item| item.fetch("id") }.to_set
    end

    def capability_package_ids
      @capability_package_ids ||= begin
        registry = load_yaml(root.join("catalog/packages_registry.yaml"))
        Array(registry["packages"]).map { |item| item.fetch("id") }.to_set
      end
    end

    def capsule_summary(path, data)
      { "id" => data.fetch("id"), "status" => data.fetch("status"), "path" => relative(path) }
    end

    def valid_relative_pattern?(value)
      return false unless value.is_a?(String) && !value.empty?
      return false if Pathname.new(value).absolute?

      !value.split("/").include?("..") && !value.include?("\\")
    end

    def path_match?(pattern, relative_path)
      return false unless valid_relative_pattern?(pattern)
      return relative_path == pattern.delete_suffix("/**") || relative_path.start_with?("#{pattern.delete_suffix('/**')}/") if pattern.end_with?("/**")

      File.fnmatch?(pattern, relative_path, File::FNM_PATHNAME | File::FNM_EXTGLOB)
    end

    def confined_path(value, errors, label)
      unless value.is_a?(String) && valid_relative_pattern?(value) && !value.match?(/[?*\[]/)
        errors << "#{label} must be a project-relative file path"
        return nil
      end
      candidate = root.join(value).cleanpath
      prefix = "#{root}#{File::SEPARATOR}"
      unless candidate.to_s.start_with?(prefix)
        errors << "#{label} escapes project root"
        return nil
      end
      candidate
    end

    def relative(path)
      path.relative_path_from(root).to_s
    end

    def fail_with!(errors)
      raise ChangeGovernanceError, errors.join("\n") unless errors.empty?
    end
  end
end
