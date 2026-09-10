# frozen_string_literal: true

require "digest"
require "fileutils"
require "find"
require "json"
require "pathname"
require "tmpdir"
require "yaml"

require_relative "remote_work"

module RemoteWork
  # Builds the deliberately small, content-addressed release used by the
  # low-privilege member worker. It never copies the owner checkout, runtime
  # state, resource bindings, credentials, or arbitrary files.
  class MemberRuntimeRelease
    EXACT_FILES = {
      "capabilities/remote-work/adapters/remote-work" => 0o555,
      "capabilities/remote-work/worker/ltw-worker" => 0o555,
      "capabilities/remote-work/worker/app_server_bridge.rb" => 0o444,
      "capabilities/remote-work/worker/owner_capability_adapters.rb" => 0o444,
      "capabilities/remote-work/worker/member-research-library" => 0o555,
      "capabilities/remote-work/worker/member_runtime_guard.rb" => 0o444,
      "capabilities/remote-work/worker/member_sandbox.rb" => 0o444,
      "capabilities/remote-work/worker/capability-adapters.yaml" => 0o444,
      "capabilities/remote-work/lib/remote_work.rb" => 0o444,
      "capabilities/agent-identity/adapters/agent-identity" => 0o555,
      "capabilities/research-library/adapters/research-library" => 0o555,
      "capabilities/remote-work/policies/owner-only.yaml" => 0o444
    }.freeze
    TREE_ROOTS = %w[
      capabilities/agent-identity/lib
      capabilities/research-library/lib/research_library
    ].freeze
    IGNORED_NAMES = %w[.DS_Store __pycache__].freeze

    attr_reader :source_root

    def initialize(source_root:)
      @source_root = Pathname.new(source_root).expand_path.cleanpath.realpath
    end

    def build(output_root:)
      output = Pathname.new(output_root).expand_path.cleanpath
      raise Error, "member release output root must be absolute" unless output.absolute?

      files = source_files
      skills = remote_task_skill_releases
      release_id = "v#{RemoteWork::VERSION}-#{source_digest(files, skills)[0, 12]}"
      releases = output.join("releases")
      FileUtils.mkdir_p(releases.to_s, mode: 0o755)
      release = releases.join(release_id)
      unless release.directory?
        stage = Pathname.new(Dir.mktmpdir("member-worker-release-", releases.to_s))
        install_files(stage, files)
        install_skills(stage, skills)
        write_manifest(stage, release_id, files, skills)
        make_runtime_immutable(stage)
        File.rename(stage.to_s, release.to_s)
      end
      verify!(release)
      release
    ensure
      FileUtils.rm_rf(stage.to_s) if defined?(stage) && stage&.exist?
    end

    def verify!(release)
      root = Pathname.new(release).expand_path.cleanpath.realpath
      manifest = JSON.parse(root.join("MEMBER_RUNTIME_MANIFEST.json").read(encoding: "UTF-8"))
      raise Error, "member runtime manifest schema is invalid" unless manifest["schema_version"] == 1
      raise Error, "member runtime release ID is invalid" unless root.basename.to_s == manifest["release_id"]
      Array(manifest.fetch("files")).each do |item|
        relative = safe_relative(item.fetch("path"))
        path = root.join(relative)
        raise Error, "member runtime release file is missing" unless path.file? && !path.symlink?
        raise Error, "member runtime release digest mismatch" unless Digest::SHA256.file(path.to_s).hexdigest == item.fetch("sha256")
        raise Error, "member runtime release is writable" if (path.stat.mode & 0o022).positive?
      end
      raise Error, "member runtime release root is writable" if (root.stat.mode & 0o022).positive?
      root
    rescue JSON::ParserError, KeyError, Errno::ENOENT
      raise Error, "member runtime release manifest is invalid"
    end

    private

    def source_files
      records = EXACT_FILES.map do |relative, mode|
        path = checked_source_file(relative)
        [relative, path, mode]
      end
      TREE_ROOTS.each do |relative_root|
        root = source_root.join(relative_root)
        raise Error, "member runtime source tree is missing: #{relative_root}" unless root.directory? && !root.symlink?
        Find.find(root.to_s) do |raw|
          path = Pathname.new(raw)
          if path.directory?
            if IGNORED_NAMES.include?(path.basename.to_s)
              Find.prune
            end
            next
          end
          raise Error, "member runtime source tree contains a symlink" if path.symlink?
          raise Error, "member runtime source tree contains a non-file" unless path.file?
          relative = path.relative_path_from(source_root).to_s
          records << [relative, path, path.executable? ? 0o555 : 0o444]
        end
      end
      records.sort_by(&:first)
    end

    def checked_source_file(relative)
      path = source_root.join(safe_relative(relative))
      raise Error, "member runtime source is missing: #{relative}" unless path.file? && !path.symlink?
      path
    end

    def safe_relative(value)
      path = Pathname.new(value.to_s).cleanpath
      raise Error, "member runtime path is unsafe" if path.absolute? || path.to_s == ".." || path.to_s.start_with?("../")
      path
    end

    def source_digest(files, skills)
      digest = Digest::SHA256.new
      files.each do |relative, path, mode|
        digest << "file\0" << relative << "\0" << format("%04o", mode) << "\0" << path.binread << "\0"
      end
      skills.each do |item|
        digest << "skill\0" << item.fetch("skill_id") << "\0" << item.fetch("digest") << "\0"
        skill_files(item.fetch("source")).each do |relative, path|
          digest << relative << "\0" << path.binread << "\0"
        end
      end
      digest.hexdigest
    end

    def install_files(stage, files)
      files.each do |relative, source, mode|
        destination = stage.join(relative)
        FileUtils.mkdir_p(destination.dirname.to_s, mode: 0o755)
        FileUtils.install(source.to_s, destination.to_s, mode: mode)
      end
    end

    def remote_task_skill_releases
      policy = YAML.safe_load(
        source_root.join("capabilities/remote-work/policies/owner-only.yaml").read(encoding: "UTF-8"),
        permitted_classes: [], aliases: false
      )
      wanted = Array(policy.dig("capability_inventory", "remote_task_skills"))
      registry = JSON.parse(source_root.join("skills/registries/skill_releases.json").read(encoding: "UTF-8"))
      releases = Array(registry.fetch("releases")).to_h do |item|
        [[item.fetch("skill_id"), item.fetch("digest")], item]
      end
      approvals = Array(registry.fetch("approvals"))
      wanted.map do |skill_id|
        digest = registry.fetch("current").fetch(skill_id)
        record = releases.fetch([skill_id, digest])
        approved = approvals.any? do |item|
          item["skill_id"] == skill_id && item["digest"] == digest &&
            item["decision"].to_s.start_with?("approved") && Array(item["runtimes"]).include?("codex")
        end
        raise Error, "member Skill is not approved for Codex: #{skill_id}" unless approved
        source = source_root.join(safe_relative(record.fetch("snapshot_path"))).realpath
        release_store = source_root.join("skills/releases").realpath
        unless source.to_s.start_with?(release_store.to_s + File::SEPARATOR) && source.basename.to_s == digest.delete_prefix("sha256:")
          raise Error, "member Skill Release path is invalid: #{skill_id}"
        end
        raise Error, "member Skill Release is missing: #{skill_id}" unless source.join("SKILL.md").file?
        { "skill_id" => skill_id, "digest" => digest, "source" => source }
      end
    rescue JSON::ParserError, Psych::Exception, KeyError, Errno::ENOENT
      raise Error, "member Skill Release registry is invalid"
    end

    def skill_files(root)
      files = []
      Find.find(root.to_s) do |raw|
        path = Pathname.new(raw)
        next if path == root
        if path.directory?
          if IGNORED_NAMES.include?(path.basename.to_s)
            Find.prune
          end
          next
        end
        raise Error, "member Skill Release contains a symlink" if path.symlink?
        raise Error, "member Skill Release contains a non-file" unless path.file?
        basename = path.basename.to_s
        if Archive.credential_shaped?(basename) || Archive::DEFAULT_EXCLUDED_NAMES.include?(basename)
          raise Error, "member Skill Release contains a forbidden file"
        end
        files << [path.relative_path_from(root).to_s, path]
      end
      raise Error, "member Skill Release is empty" if files.empty?
      files.sort_by(&:first)
    end

    def install_skills(stage, skills)
      bundle = stage.join("skills/remote-task")
      FileUtils.mkdir_p(bundle.to_s, mode: 0o755)
      skills.each do |item|
        target = bundle.join(item.fetch("skill_id"))
        skill_files(item.fetch("source")).each do |relative, source|
          destination = target.join(relative)
          FileUtils.mkdir_p(destination.dirname.to_s, mode: 0o755)
          FileUtils.install(source.to_s, destination.to_s, mode: source.executable? ? 0o555 : 0o444)
        end
      end
    end

    def write_manifest(stage, release_id, files, skills)
      installed_files = files.map do |relative, _source, mode|
        path = stage.join(relative)
        { "path" => relative, "sha256" => Digest::SHA256.file(path.to_s).hexdigest, "mode" => format("%04o", mode) }
      end
      skills.each do |item|
        skill_files(item.fetch("source")).each do |relative, _source|
          installed = stage.join("skills/remote-task", item.fetch("skill_id"), relative)
          installed_files << {
            "path" => installed.relative_path_from(stage).to_s,
            "sha256" => Digest::SHA256.file(installed.to_s).hexdigest,
            "mode" => format("%04o", installed.executable? ? 0o555 : 0o444)
          }
        end
      end
      payload = {
        "schema_version" => 1,
        "release_id" => release_id,
        "remote_work_version" => RemoteWork::VERSION,
        "files" => installed_files.sort_by { |item| item.fetch("path") },
        "skills" => skills.map { |item| item.slice("skill_id", "digest") }
      }
      stage.join("MEMBER_RUNTIME_MANIFEST.json").write(JSON.pretty_generate(payload) + "\n", encoding: "UTF-8")
    end

    def make_runtime_immutable(root)
      Find.find(root.to_s).to_a.sort.reverse_each do |raw|
        path = Pathname.new(raw)
        next if path.symlink?
        File.chmod(path.directory? ? 0o755 : (path.executable? ? 0o755 : 0o644), path.to_s)
      end
    end
  end
end
