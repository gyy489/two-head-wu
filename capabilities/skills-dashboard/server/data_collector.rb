# frozen_string_literal: true

require "yaml"
require "pathname"
require "time"

module SkillsDashboard
  # Builds the skills/capabilities relationship graph from the project's own
  # registries. Read-only: it never writes anything and never touches Codex
  # auth state, credentials, or private identity directories.
  #
  # Node kinds: skill, skill_set, capability, runtime, external (external is
  # synthesized client-side for any edge target with no matching node).
  #
  # Edge types and how each is derived (all "evidence" edges are read straight
  # out of a registry field; only "inferred_uses" is a heuristic guess):
  #   member_of         skill_sets.<set>.skills            (capabilities_registry.yaml)
  #   owns              capability.yaml components.skills  (per capability)
  #   depends_on        capability.yaml dependencies        (per capability)
  #   available_to      skill_sets.<set>.compatibility      (per runtime, native/compatible only)
  #   inferred_uses     SKILL.md body text mentions another skill's name (heuristic, not verified)
  class DataCollector
    SKILLS_REGISTRY = "skills/registries/skills_registry.yaml"
    CAPABILITIES_REGISTRY = "registries/capabilities_registry.yaml"
    CAPABILITY_GLOB = "capabilities/*/capability.yaml"
    RUNTIMES = %w[codex claude-code openclaw].freeze
    VISIBLE_COMPATIBILITY_STATES = %w[native compatible].freeze

    def initialize(project_root)
      @root = Pathname.new(project_root).expand_path
    end

    def build
      skills = load_skills_registry
      skill_sets = load_skill_sets
      capabilities = load_capabilities

      {
        "generated_at" => Time.now.utc.iso8601,
        "project_root" => @root.to_s,
        "nodes" => build_nodes(skills, skill_sets, capabilities),
        "edges" => build_edges(skills, skill_sets, capabilities)
      }
    end

    private

    def load_skills_registry
      path = @root.join(SKILLS_REGISTRY)
      return [] unless path.exist?

      data = YAML.load_file(path.to_s) || {}
      Array(data["skills"])
    end

    def load_skill_sets
      path = @root.join(CAPABILITIES_REGISTRY)
      return {} unless path.exist?

      data = YAML.load_file(path.to_s) || {}
      data["skill_sets"] || {}
    end

    def load_capabilities
      Dir.glob(@root.join(CAPABILITY_GLOB).to_s).sort.map do |file|
        data = YAML.load_file(file) || {}
        data["id"] ||= File.basename(File.dirname(file))
        data
      end
    end

    def build_nodes(skills, skill_sets, capabilities)
      nodes = []
      skills.each do |skill|
        nodes << {
          "id" => "skill:#{skill['name']}",
          "kind" => "skill",
          "label" => skill["name"],
          "category" => skill["category"],
          "provenance" => skill["provenance"],
          "status" => skill["status"],
          "path" => skill["path"],
          "active_path" => skill["active_path"],
          "entrypoint" => skill["entrypoint"],
          "risk_level" => skill["risk_level"],
          "network_access" => skill["network_access"],
          "filesystem_access" => skill["filesystem_access"],
          "purpose" => skill["purpose"]
        }
      end
      skill_sets.each do |name, meta|
        nodes << {
          "id" => "skill_set:#{name}",
          "kind" => "skill_set",
          "label" => name,
          "description" => meta["description"],
          "compatibility" => meta["compatibility"]
        }
      end
      capabilities.each do |capability|
        nodes << {
          "id" => "capability:#{capability['id']}",
          "kind" => "capability",
          "label" => capability["id"],
          "version" => capability["version"],
          "summary" => capability["summary"],
          "risk_level" => capability.dig("permissions", "risk_level")
        }
      end
      RUNTIMES.each do |runtime|
        nodes << { "id" => "runtime:#{runtime}", "kind" => "runtime", "label" => runtime }
      end
      nodes
    end

    def build_edges(skills, skill_sets, capabilities)
      edges = []
      edges.concat(skill_set_membership_edges(skill_sets))
      edges.concat(runtime_availability_edges(skill_sets))
      edges.concat(capability_ownership_edges(capabilities))
      edges.concat(capability_dependency_edges(capabilities))
      edges.concat(inferred_usage_edges(skills))
      edges
    end

    def skill_set_membership_edges(skill_sets)
      skill_sets.each_with_object([]) do |(set_name, meta), edges|
        Array(meta["skills"]).each do |skill_name|
          edges << {
            "source" => "skill:#{skill_name}",
            "target" => "skill_set:#{set_name}",
            "type" => "member_of",
            "confidence" => "evidence",
            "evidence" => "registries/capabilities_registry.yaml skill_sets.#{set_name}.skills"
          }
        end
      end
    end

    def runtime_availability_edges(skill_sets)
      edges = []
      skill_sets.each do |set_name, meta|
        compatibility = meta["compatibility"] || {}
        Array(meta["skills"]).each do |skill_name|
          RUNTIMES.each do |runtime|
            state = compatibility[runtime]
            next unless VISIBLE_COMPATIBILITY_STATES.include?(state)

            edges << {
              "source" => "skill:#{skill_name}",
              "target" => "runtime:#{runtime}",
              "type" => "available_to",
              "confidence" => "evidence",
              "state" => state,
              "evidence" => "capabilities_registry.yaml skill_sets.#{set_name}.compatibility.#{runtime} = #{state}"
            }
          end
        end
      end
      edges
    end

    def capability_ownership_edges(capabilities)
      capabilities.each_with_object([]) do |capability, edges|
        Array(capability.dig("components", "skills")).each do |relative_path|
          skill_name = File.basename(relative_path)
          edges << {
            "source" => "capability:#{capability['id']}",
            "target" => "skill:#{skill_name}",
            "type" => "owns",
            "confidence" => "evidence",
            "evidence" => "capabilities/#{capability['id']}/capability.yaml components.skills"
          }
        end
      end
    end

    def capability_dependency_edges(capabilities)
      known_ids = capabilities.map { |c| c["id"] }
      capabilities.each_with_object([]) do |capability, edges|
        Array(capability["dependencies"]).each do |dependency|
          dependency_id = dependency["id"]
          next unless dependency_id

          target_kind = known_ids.include?(dependency_id) ? "capability" : "external"
          edges << {
            "source" => "capability:#{capability['id']}",
            "target" => "#{target_kind}:#{dependency_id}",
            "type" => "depends_on",
            "confidence" => "evidence",
            "evidence" => "capabilities/#{capability['id']}/capability.yaml dependencies"
          }
        end
      end
    end

    # Heuristic only: a skill's SKILL.md body mentioning another registered
    # skill's name is not proof of an actual call/dependency. Every edge here
    # carries the matched text so a human can judge it, and the UI marks it
    # visually distinct from evidence-backed edges.
    def inferred_usage_edges(skills)
      names = skills.map { |s| s["name"] }.compact.uniq
      skills.each_with_object([]) do |skill, edges|
        body = read_skill_body(skill)
        next unless body

        names.each do |other_name|
          next if other_name == skill["name"]

          snippet = matching_snippet(body, other_name)
          next unless snippet

          edges << {
            "source" => "skill:#{skill['name']}",
            "target" => "skill:#{other_name}",
            "type" => "inferred_uses",
            "confidence" => "inferred",
            "evidence" => snippet
          }
        end
      end
    end

    def read_skill_body(skill)
      base = skill["active_path"] || skill["path"]
      return nil unless base

      file = @root.join(base, skill["entrypoint"] || "SKILL.md")
      return nil unless file.file?

      file.read(encoding: "UTF-8").sub(/\A---\n.*?\n---\n/m, "")
    rescue Errno::ENOENT, Errno::EACCES, ArgumentError
      nil
    end

    def matching_snippet(body, other_name)
      pattern = /(?<![\w-])#{Regexp.escape(other_name)}(?![\w-])/
      match = pattern.match(body)
      return nil unless match

      start = [match.begin(0) - 40, 0].max
      finish = [match.end(0) + 40, body.length].min
      body[start...finish].gsub(/\s+/, " ").strip
    end
  end
end
