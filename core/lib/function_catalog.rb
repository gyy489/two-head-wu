# frozen_string_literal: true

require "date"
require "digest"
require "json"
require "pathname"
require "yaml"

module TwoHeadWu
  class FunctionCatalog
    class Error < StandardError; end

    EXECUTION_OPTIONAL_FIELDS = %w[
      command tool_id data_location input_schema output_schema executor_kind adapter capability_version
      replay_class approval_policy
    ].freeze
    REMOTE_EXECUTION_FIELDS = (%w[
      id name kind location exposure status invocation_policy side_effect queueable runtime_requires summary
    ] + EXECUTION_OPTIONAL_FIELDS).freeze
    REMOTE_INVENTORY_FIELDS = %w[
      id kind name summary status air_mode location version native_status category callable_via
    ].freeze
    CALLABLE_MODES = %w[remote-auto remote-queue confirm].freeze

    attr_reader :root

    def initialize(root)
      @root = Pathname.new(root).expand_path.cleanpath
    end

    def manifest
      execution = execution_entries
      inventory = inventory_entries
      payload = { "execution_entries" => execution, "inventory_entries" => inventory }
      {
        "schema_version" => 1,
        "catalog_version" => Digest::SHA256.hexdigest(JSON.generate(payload))[0, 16],
        "updated_at" => updated_at,
        "source_device" => "mac-mini",
        "counts" => {
          "execution_entries" => execution.length,
          "inventory_entries" => inventory.length,
          "inventory_by_kind" => counts(inventory, "kind"),
          "inventory_by_air_mode" => counts(inventory, "air_mode")
        },
        "execution_entries" => execution,
        "inventory_entries" => inventory,
        "policy_note" => "功能总表用于发现，不等于授权；调用时仍须重新验证入口、参数、设备、身份与权限。"
      }
    end

    def execution_entries
      entries = Array(owner_policy.dig("capability_directory", "entries")).map do |entry|
        record = {
          "id" => entry.fetch("id"),
          "name" => safe_text(entry.fetch("name"), 160),
          "kind" => entry.fetch("kind"),
          "location" => entry.fetch("location"),
          "exposure" => entry.fetch("exposure"),
          "status" => entry.fetch("status"),
          "invocation_policy" => entry.fetch("invocation_policy"),
          "side_effect" => entry.fetch("side_effect"),
          "queueable" => entry.fetch("queueable"),
          "runtime_requires" => Array(entry["runtime_requires"]),
          "summary" => safe_text(entry.fetch("summary"), 1000),
          "documentation" => "capabilities/remote-work/README.md"
        }
        EXECUTION_OPTIONAL_FIELDS.each { |key| record[key] = entry[key] if entry.key?(key) }
        record
      end
      ensure_unique!(entries, "execution")
      entries.sort_by { |entry| entry.fetch("id") }
    end

    def remote_execution_entries
      execution_entries.map { |entry| entry.select { |key, _value| REMOTE_EXECUTION_FIELDS.include?(key) } }
    end

    def inventory_entries
      entries = []
      policy = owner_policy.fetch("capability_inventory")
      modules = Array(owner_policy.dig("modules", "entries"))
      module_by_id = modules.each_with_object({}) { |item, output| output[item.fetch("id")] = item }
      remote_skills = Array(policy["remote_task_skills"])
      metadata_skills = Array(policy["metadata_only_skills"])
      categories = Hash(policy["skill_categories"]).each_with_object({}) do |(category, ids), output|
        Array(ids).each { |id| output[id] = category }
      end
      registered_skills = index_by(safe_yaml("skills/registries/skills_registry.yaml").fetch("skills"), "name")

      skill_inventory_rows(registered_skills).each do |skill_id, registry_entry, metadata|
        module_entry = module_by_id["skill:#{skill_id}"]
        mode = if module_entry && module_entry["classification"] == "portable"
                 "portable"
               elsif remote_skills.include?(skill_id)
                 "remote-queue"
               else
                 "metadata-only"
               end
        if remote_skills.include?(skill_id) && metadata_skills.include?(skill_id)
          raise Error, "Mini Skill inventory policy overlaps for #{skill_id}"
        end
        entries << inventory_entry(
          id: "skill:#{skill_id}", kind: "skill", name: skill_id,
          summary: registry_entry["purpose"] || metadata.fetch("description"),
          native_status: registry_entry.fetch("status", "active"), air_mode: mode,
          location: "mac-mini", category: categories.fetch(skill_id, registry_entry.fetch("category", "other")),
          callable_via: mode == "remote-queue" ? "codex:project-task" : nil,
          documentation: relative_skill_document(registry_entry)
        )
      end

      Array(safe_yaml("catalog/packages_registry.yaml").fetch("packages")).each do |item|
        manifest = safe_yaml(item.fetch("manifest"))
        entries << inventory_entry(
          id: "package:#{item.fetch('id')}", kind: "capability-package", name: item.fetch("id"),
          summary: item.fetch("summary"), native_status: item.fetch("status"), air_mode: "metadata-only",
          location: "mac-mini", category: "system-management", version: item["version"],
          documentation: manifest.dig("documentation", "overview") || item.fetch("manifest")
        )
      end

      agent_modes = Hash(policy["agent_modes"])
      Array(safe_yaml("registries/agents_registry.yaml").fetch("agents")).each do |item|
        mode = agent_modes.fetch(item.fetch("id"), "metadata-only")
        entries << inventory_entry(
          id: "agent:#{item.fetch('id')}", kind: "agent", name: item.fetch("name", item.fetch("id")),
          summary: item.fetch("notes", item.fetch("kind")), native_status: item.fetch("status"), air_mode: mode,
          location: "mac-mini", category: item.fetch("category", "agents"), version: item["version"],
          callable_via: CALLABLE_MODES.include?(mode) ? "codex:project-task" : nil,
          documentation: item["manifest"] || "registries/agents_registry.yaml"
        )
      end

      mcp_modes = Hash(policy["mcp_modes"])
      Array(safe_yaml("catalog/mcp_registry.yaml").fetch("servers")).each do |item|
        mode = mcp_modes.fetch(item.fetch("id"), "metadata-only")
        entries << inventory_entry(
          id: "mcp:#{id_component(item.fetch('id'))}", kind: "mcp-server", name: item.fetch("name", item.fetch("id")),
          summary: item.fetch("notes", "已登记的 Mini MCP 能力。"), native_status: item.fetch("status"), air_mode: mode,
          location: "mac-mini", category: "integrations",
          callable_via: CALLABLE_MODES.include?(mode) ? "codex:project-task" : nil,
          documentation: "catalog/mcp_registry.yaml"
        )
      end

      known_ids = entries.map { |entry| entry.fetch("id") }
      modules.each do |item|
        next unless item.fetch("classification") == "remote-only"
        next if known_ids.include?(item.fetch("id"))

        kind = item.fetch("id").start_with?("mcp:") ? "mcp-server" : "resource"
        entries << inventory_entry(
          id: item.fetch("id"), kind: kind, name: item.fetch("id").split(":", 2).last,
          summary: item.fetch("summary"), native_status: item.fetch("status"), air_mode: "metadata-only",
          location: "mac-mini", category: "protected-data",
          documentation: "capabilities/remote-work/README.md"
        )
      end

      runtime_modes = Hash(policy["runtime_modes"])
      Array(safe_yaml("registries/runtimes_registry.yaml").fetch("runtimes")).each do |item|
        mode = runtime_modes.fetch(item.fetch("id"), "metadata-only")
        entries << inventory_entry(
          id: "runtime:#{item.fetch('id')}", kind: "runtime", name: item.fetch("name", item.fetch("id")),
          summary: "Mini 已登记的 #{item.fetch('kind').tr('_', ' ')}。", native_status: item.fetch("status"), air_mode: mode,
          location: "mac-mini", category: "runtimes",
          callable_via: CALLABLE_MODES.include?(mode) ? "codex:project-task" : nil,
          documentation: "registries/runtimes_registry.yaml"
        )
      end

      Array(safe_yaml("catalog/workflows_registry.yaml").fetch("workflows")).each do |item|
        entries << inventory_entry(
          id: "workflow:#{item.fetch('id')}", kind: "workflow", name: item.fetch("id"),
          summary: item.fetch("purpose"), native_status: "registered", air_mode: "metadata-only",
          location: "mac-mini", category: "system-workflows", documentation: "catalog/workflows_registry.yaml"
        )
      end

      Array(safe_yaml("catalog/resources/infrastructure.yaml").fetch("resources")).each do |item|
        location = item.fetch("id") == "local-mac" ? "mac-mini" : (item.fetch("id") == "edge-server" ? "aliyun" : "external")
        entries << inventory_entry(
          id: "resource:#{item.fetch('id')}", kind: "resource", name: item.fetch("id"),
          summary: item.fetch("summary"), native_status: "registered", air_mode: "metadata-only",
          location: location, category: "infrastructure", documentation: "catalog/resources/infrastructure.yaml"
        )
      end
      Array(safe_yaml("catalog/deployments/personal-static-sites.yaml").fetch("sites")).each do |item|
        entries << inventory_entry(
          id: "resource:#{item.fetch('id')}", kind: "resource", name: item.fetch("id"),
          summary: item.fetch("summary"), native_status: "registered", air_mode: "metadata-only",
          location: "aliyun", category: "registered-sites", documentation: "catalog/deployments/personal-static-sites.yaml"
        )
      end

      ensure_unique!(entries, "inventory")
      entries.sort_by { |entry| entry.fetch("id") }
    end

    def remote_inventory_entries
      inventory_entries.map { |entry| entry.select { |key, _value| REMOTE_INVENTORY_FIELDS.include?(key) } }
    end

    def markdown
      data = manifest
      lines = [
        "# 两头乌统一功能清单",
        "",
        "由 `wu 更新说明` 从登记表和当前激活面生成。目录版本：`#{data.fetch('catalog_version')}`；登记日期：`#{data.fetch('updated_at')}`。不要手工编辑本文件。",
        "",
        "> 这份清单把“精确执行入口”和“完整组件”分开。组件可被发现不代表已获授权或已经接线；实际调用仍按策略逐次验证。",
        "",
        "## 精确工具与执行入口（#{data.dig('counts', 'execution_entries')}）",
        "",
        "| 名称 | ID | 功能 | 位置 / 调用策略 | 使用入口 | 说明 |",
        "|---|---|---|---|---|---|"
      ]
      data.fetch("execution_entries").each do |entry|
        lines << "| #{escape(entry.fetch('name'))} | `#{entry.fetch('id')}` | #{escape(entry.fetch('summary'))} | `#{entry.fetch('location')}` / `#{entry.fetch('invocation_policy')}` | #{entry['command'] ? "`#{escape(entry['command'])}`" : "—"} | #{doc_link(entry)} |"
      end
      lines.concat([
        "",
        "## 完整组件功能表（#{data.dig('counts', 'inventory_entries')}）",
        "",
        "| 类型 | 名称 | ID | 功能 | Air 使用方式 | 状态 | 说明 |",
        "|---|---|---|---|---|---|---|"
      ])
      data.fetch("inventory_entries").sort_by { |entry| [entry.fetch("kind"), entry.fetch("id")] }.each do |entry|
        lines << "| `#{entry.fetch('kind')}` | #{escape(entry.fetch('name'))} | `#{entry.fetch('id')}` | #{escape(entry.fetch('summary'))} | `#{entry.fetch('air_mode')}` | `#{entry.fetch('status')}` | #{doc_link(entry)} |"
      end
      lines.concat([
        "",
        "## 机器读取",
        "",
        "同源 JSON：[`function_catalog.json`](function_catalog.json)。Mini 本地运行 `wu 功能清单 --json`；Air 运行 `wu 能做什么 --json` 获取已验签的实时目录或可信缓存。",
        ""
      ])
      lines.join("\n")
    end

    private

    def inventory_entry(id:, kind:, name:, summary:, native_status:, air_mode:, location:, category:, version: nil, callable_via: nil, documentation:)
      configured_route = Hash(owner_policy.dig("capability_inventory", "callable_via"))[id]
      if configured_route
        execution = execution_entry_index.fetch(configured_route) do
          raise Error, "inventory route references unknown execution entry: #{id} -> #{configured_route}"
        end
        unless execution.fetch("exposure") == "callable" && execution.fetch("status") == "active"
          raise Error, "inventory route references an unavailable execution entry: #{id}"
        end
        air_mode = {
          "auto" => "remote-auto",
          "queue" => "remote-queue",
          "confirm" => "confirm"
        }.fetch(execution.fetch("invocation_policy")) do
          raise Error, "inventory route has unsupported invocation policy: #{configured_route}"
        end
        callable_via = configured_route
      end
      record = {
        "id" => id,
        "kind" => kind,
        "name" => safe_text(name, 160),
        "summary" => safe_text(summary, 1000),
        "status" => normalized_status(native_status, air_mode),
        "air_mode" => air_mode,
        "location" => location,
        "native_status" => safe_text(native_status, 160),
        "category" => safe_text(category, 160),
        "documentation" => documentation
      }
      record["version"] = safe_text(version, 160) if version
      record["callable_via"] = callable_via if callable_via
      record
    end

    def execution_entry_index
      @execution_entry_index ||= execution_entries.to_h { |entry| [entry.fetch("id"), entry] }
    end

    def normalized_status(native_status, air_mode)
      value = native_status.to_s.downcase
      return "unavailable" if air_mode == "unavailable"
      return "planned" if value.include?("planned")
      return "active" if value.include?("configured_codex_plugin")
      return "unconfigured" if value.include?("unconfigured") || value.include?("not_configured")
      return "experimental" if value.include?("experimental")
      return "disabled" if value.include?("disabled")
      return "active" if value.match?(/active|running|verified|configured|installed|registered/)

      "unknown"
    end

    def active_skill_paths
      paths = root.glob("skills/.active/*/SKILL.md") + root.glob("skills/.active/.system/*/SKILL.md")
      paths.select(&:file?).sort_by(&:to_s)
    end

    def skill_inventory_rows(registered_skills)
      paths = active_skill_paths
      if root.join("MIRROR_COMMIT").file? || paths.empty?
        return registered_skills.values
                                .select { |entry| entry.fetch("status", "active") == "active" }
                                .sort_by { |entry| entry.fetch("name") }
                                .map do |entry|
          [entry.fetch("name"), entry, { "description" => entry.fetch("purpose", entry.fetch("name")) }]
        end
      end

      paths.map do |skill_path|
        metadata = skill_frontmatter(skill_path)
        skill_id = metadata.fetch("name")
        registry_entry = registered_skills.fetch(skill_id) { raise Error, "active Skill is not registered: #{skill_id}" }
        [skill_id, registry_entry, metadata]
      end
    end

    def skill_frontmatter(skill_path)
      match = skill_path.read(encoding: "UTF-8").match(/\A---\s*\n(.*?)\n---\s*\n/m)
      raise Error, "active Skill frontmatter is invalid: #{skill_path}" unless match

      metadata = YAML.safe_load(match[1], permitted_classes: [], aliases: false)
      unless metadata.is_a?(Hash) && metadata["name"] && metadata["description"]
        raise Error, "active Skill metadata is incomplete: #{skill_path}"
      end
      metadata
    end

    def relative_skill_document(entry)
      base = entry.fetch("path")
      "#{base}/#{entry.fetch('entrypoint', 'SKILL.md')}"
    end

    def safe_yaml(relative)
      path = root.join(relative).cleanpath
      raise Error, "catalog source is missing: #{relative}" unless path.file?

      data = YAML.safe_load(path.read(encoding: "UTF-8"), permitted_classes: [Date, Time], aliases: false)
      raise Error, "catalog source is not a mapping: #{relative}" unless data.is_a?(Hash)

      data
    end

    def owner_policy
      @owner_policy ||= safe_yaml("capabilities/remote-work/policies/owner-only.yaml")
    end

    def updated_at
      sources = %w[
        skills/registries/skills_registry.yaml catalog/packages_registry.yaml registries/agents_registry.yaml
        catalog/mcp_registry.yaml registries/runtimes_registry.yaml catalog/workflows_registry.yaml
        catalog/resources/infrastructure.yaml catalog/deployments/personal-static-sites.yaml
      ]
      dates = sources.map { |relative| safe_yaml(relative)["updated_at"] }.compact.map(&:to_s)
      dates.max || "unknown"
    end

    def index_by(items, key)
      Array(items).each_with_object({}) do |item, output|
        value = item.fetch(key)
        raise Error, "duplicate #{key}: #{value}" if output.key?(value)
        output[value] = item
      end
    end

    def ensure_unique!(entries, label)
      ids = entries.map { |entry| entry.fetch("id") }
      raise Error, "#{label} catalog contains duplicate IDs" unless ids.uniq.length == ids.length
    end

    def counts(entries, field)
      entries.group_by { |entry| entry.fetch(field) }.transform_values(&:length).sort.to_h
    end

    def safe_text(value, maximum)
      text = value.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "").gsub(/\s+/, " ").strip
      raise Error, "function catalog contains empty metadata" if text.empty?
      text[0, maximum]
    end

    def id_component(value)
      component = value.to_s.downcase.tr("_", "-")
      raise Error, "function catalog contains an invalid registry ID" unless component.match?(/\A[a-z][a-z0-9-]*\z/)
      component
    end

    def doc_link(entry)
      relative = entry["documentation"]
      relative ? "[打开](../#{relative})" : "—"
    end

    def escape(value)
      value.to_s.gsub("|", "&#124;").tr("\n", " ")
    end
  end
end
