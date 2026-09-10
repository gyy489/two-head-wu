# frozen_string_literal: true

require "json"
require "net/http"
require "open3"
require "pathname"
require "time"
require "timeout"
require "uri"
require "yaml"

module RemoteWork
  # Owner-only adapters that expose fixed, structured Mini capabilities without
  # accepting arbitrary commands, paths, endpoints, or credential material.
  class OwnerCapabilityAdapters
    MCP_ENDPOINT = "https://developers.openai.com/mcp"
    MCP_PROTOCOL_VERSION = "2025-06-18"
    MAX_MCP_RESPONSE_BYTES = 4 * 1024 * 1024
    MAX_WORKFLOW_OUTPUT_BYTES = 1024 * 1024
    MAX_ARTIFACT_BYTES = 50 * 1024 * 1024
    RESOURCE_ID = /\A[a-z][a-z0-9-]{0,62}\z/.freeze
    UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i.freeze
    SHA256 = /\A[a-f0-9]{64}\z/.freeze
    RESEARCH_KINDS = %w[article conference-paper thesis book chapter interview web-article report published-owner-work].freeze
    SAFE_DOC_URL = %r{\A(?:https://developers\.openai\.com/|/)[^\s]*\z}.freeze
    MCP_ACTIONS = {
      "search" => "search_openai_docs",
      "list" => "list_openai_docs",
      "fetch" => "fetch_openai_doc",
      "list-api-endpoints" => "list_api_endpoints",
      "get-openapi-spec" => "get_openapi_spec"
    }.freeze
    ArtifactExport = Struct.new(:path, :filename, :media_type, :payload, keyword_init: true)

    def initialize(runtime_root:, source_root:, pipeline_root:, identity_adapter:, version:)
      @runtime_root = Pathname.new(runtime_root).expand_path.cleanpath
      @source_root = Pathname.new(source_root).expand_path.cleanpath
      @pipeline_root = Pathname.new(pipeline_root).expand_path.cleanpath
      @identity_adapter = identity_adapter.to_s
      @version = version.to_s
    end

    def source_workflows_available?
      return @source_workflows_available unless @source_workflows_available.nil?

      required = [
        @source_root.join("catalog/workflows_registry.yaml"),
        @source_root.join("core/bin/wu")
      ]
      @source_workflows_available = @source_root.directory? && required.all?(&:file?) &&
                                    source_execution_probe(required.last)
    rescue Errno::EACCES
      @source_workflows_available = false
    end

    def air_sync_pipeline_available?
      required = [
        @pipeline_root.join("MIRROR_COMMIT"),
        @pipeline_root.join("capabilities/remote-work/adapters/air-sync-pipeline")
      ]
      @pipeline_root.directory? && required.all?(&:file?) && source_execution_probe(required.last, root: @pipeline_root)
    rescue Errno::EACCES
      false
    end

    def research_library_available?
      value = run_research_library("状态")
      value["healthy"] == true
    rescue Error
      false
    end

    def identity_catalog
      stdout, _stderr, status = Open3.capture3(@identity_adapter, "status", "--json")
      raise Error, "Mini identity catalog is unavailable" unless status.success?

      value = JSON.parse(stdout)
      identities = Array(value["identities"]).map do |item|
        raise Error, "Mini identity catalog returned invalid data" unless item.is_a?(Hash)
        item.slice("id", "state_kind", "selection_mode", "configured", "shared_skills", "conversation_pool")
      end
      {
        "schema" => "two-head-wu.identity-catalog.v1",
        "source_device" => "mac-mini-worker",
        "observed_at" => Time.now.utc.iso8601,
        "identities" => identities,
        "project_bindings" => Hash(value["project_bindings"]).sort.to_h
      }
    rescue JSON::ParserError, TypeError
      raise Error, "Mini identity catalog returned invalid data"
    end

    def resource_catalog(input)
      require_object!(input)
      unknown = input.keys - ["id"]
      raise Error, "resource catalog input contains unknown fields" unless unknown.empty?
      selected = input["id"]
      if selected && (!selected.is_a?(String) || !RESOURCE_ID.match?(selected))
        raise Error, "resource ID is invalid"
      end

      infrastructure = safe_yaml("catalog/resources/infrastructure.yaml")
      deployments = safe_yaml("catalog/deployments/personal-static-sites.yaml")
      resources = Array(infrastructure["resources"]).map do |item|
        {
          "id" => item.fetch("id"),
          "kind" => item.fetch("kind"),
          "summary" => item.fetch("summary"),
          "roles" => Array(item["roles"]),
          "allowed_actions" => safe_resource_actions(item.dig("operations", "allowed_actions")),
          "change_control" => item.dig("operations", "change_control"),
          "execution_status" => item.dig("operations", "execution_status")
        }.compact
      end
      sites = Array(deployments["sites"]).map do |item|
        {
          "id" => item.fetch("id"),
          "kind" => "static-site",
          "summary" => item.fetch("summary"),
          "public_url" => item.fetch("public_url"),
          "access" => item.fetch("access"),
          "content_mode" => item.fetch("content_mode"),
          "lifecycle" => item.fetch("lifecycle"),
          "target_resource" => item.fetch("target_resource"),
          "execution_status" => item.dig("publication_policy", "execution_status")
        }.compact
      end
      entries = (resources + sites).select { |item| selected.nil? || item.fetch("id") == selected }
      raise Error, "resource is not registered" if selected && entries.empty?

      {
        "schema" => "two-head-wu.resource-catalog.v1",
        "source_device" => "mac-mini-worker",
        "observed_at" => Time.now.utc.iso8601,
        "entries" => entries.sort_by { |item| [item.fetch("kind"), item.fetch("id")] }
      }
    end

    def openai_docs(input)
      require_object!(input)
      action = input["action"]
      tool = MCP_ACTIONS[action]
      raise Error, "OpenAI Docs action is unavailable" unless tool

      arguments = openai_docs_arguments(action, input)
      result = mcp_request("tools/call", { "name" => tool, "arguments" => arguments })
      raise Error, "OpenAI Docs MCP returned an error" if result["isError"] == true
      {
        "schema" => "two-head-wu.openai-docs.v1",
        "source_device" => "mac-mini-worker",
        "observed_at" => Time.now.utc.iso8601,
        "server" => "openai-developer-docs",
        "tool" => tool,
        "result" => result
      }
    end

    def research_library_search(input)
      require_object!(input)
      allowed = %w[query type limit]
      raise Error, "research search input contains unknown fields" unless (input.keys - allowed).empty?
      query = input["query"]
      raise Error, "research search query is invalid" unless query.is_a?(String) && query.length.between?(1, 2000)
      limit = input.fetch("limit", 30)
      raise Error, "research search limit is invalid" unless limit.is_a?(Integer) && limit.between?(1, 100)
      kind = input["type"]
      raise Error, "research search type is invalid" if kind && !RESEARCH_KINDS.include?(kind)

      arguments = ["--query", query, "--limit", limit.to_s]
      arguments.concat(["--type", kind]) if kind
      data = run_research_library("搜索", *arguments)
      results = Array(data["results"]).first(limit).map { |item| safe_research_result(item) }
      {
        "schema" => "two-head-wu.research-library.search.v1",
        "source_device" => "mac-mini-worker",
        "observed_at" => Time.now.utc.iso8601,
        "provider" => "research-library.search.v1",
        "partial" => data["partial"] == true,
        "query" => query,
        "results" => results
      }
    end

    def research_library_get(input)
      document = research_document(input)
      {
        "schema" => "two-head-wu.research-library.get.v1",
        "source_device" => "mac-mini-worker",
        "observed_at" => Time.now.utc.iso8601,
        "document" => safe_research_document(document)
      }
    end

    def research_library_export(input)
      document = research_artifact(input)
      path = Pathname.new(document.fetch("artifact_path")).expand_path.cleanpath
      unless path.absolute? && path.file? && !path.symlink?
        raise Error, "research artifact is unavailable"
      end
      size = path.size
      raise Error, "research artifact is empty" unless size.positive?
      raise Error, "research artifact exceeds the 50 MiB relay limit" if size > MAX_ARTIFACT_BYTES
      digest = document.fetch("sha256").to_s
      raise Error, "research artifact digest is invalid" unless SHA256.match?(digest)
      extension = path.extname.downcase
      extension = "" unless extension.match?(/\A\.[a-z0-9]{1,12}\z/)
      filename = "research-#{document.fetch('work_id')}-#{document.fetch('version_id')}#{extension}"
      ArtifactExport.new(
        path: path,
        filename: filename,
        media_type: document.fetch("mime", "application/octet-stream").to_s,
        payload: {
          "schema" => "two-head-wu.research-library.export.v1",
          "source_device" => "mac-mini-worker",
          "observed_at" => Time.now.utc.iso8601,
          "document" => safe_research_document(document),
          "relay" => { "retention_days" => 14, "maximum_bytes" => MAX_ARTIFACT_BYTES }
        }
      )
    end

    def run_workflow(adapter, input, owner_confirmed:)
      require_object!(input)
      raise Error, "workflow input must be empty" unless input.empty?
      execution_root = workflow_execution_root(adapter)
      if execution_root == @source_root && !source_workflows_available?
        raise Error, "Mini project workflow source is unavailable"
      end
      if execution_root == @pipeline_root && !air_sync_pipeline_available?
        raise Error, "Mini Air synchronization pipeline source is unavailable"
      end
      if adapter["requires_owner_confirmation"] == true && !owner_confirmed
        raise Error, "workflow requires owner confirmation"
      end

      command = Array(adapter["command"])
      validate_workflow_command!(command, execution_root)
      utf8_environment = { "LANG" => "en_US.UTF-8", "LC_ALL" => "en_US.UTF-8" }
      stdout, stderr, status = Open3.capture3(utf8_environment, *command, chdir: execution_root.to_s)
      unless status.success?
        detail = sanitize_workflow_output([stderr, stdout].join("\n")).byteslice(0, 600).to_s.strip
        suffix = detail.empty? ? "" : ": #{detail}"
        raise Error, "registered Mini workflow failed (status #{status.exitstatus})#{suffix}"
      end
      if adapter["structured_stdout"] == true
        value = JSON.parse(stdout)
        unless value.is_a?(Hash) && value["schema"] == adapter.fetch("output_schema")
          raise Error, "registered Mini workflow returned invalid structured output"
        end
        return value
      end
      {
        "schema" => "two-head-wu.workflow-result.v1",
        "source_device" => "mac-mini-worker",
        "observed_at" => Time.now.utc.iso8601,
        "workflow" => adapter.fetch("capability_id").split(":", 2).last,
        "status" => "completed",
        "exit_status" => status.exitstatus,
        "stdout" => sanitize_workflow_output(stdout),
        "stderr" => sanitize_workflow_output(stderr)
      }
    rescue JSON::ParserError
      raise Error, "registered Mini workflow returned invalid structured output"
    end

    private

    def safe_yaml(relative)
      path = @runtime_root.join(relative).cleanpath
      prefix = @runtime_root.to_s + File::SEPARATOR
      raise Error, "bundled catalog path escaped the worker runtime" unless path.to_s.start_with?(prefix)
      raise Error, "bundled Mini catalog is unavailable" unless path.file?
      value = YAML.safe_load(path.read(encoding: "UTF-8"), permitted_classes: [], aliases: false)
      raise Error, "bundled Mini catalog is invalid" unless value.is_a?(Hash)
      value
    rescue Psych::Exception
      raise Error, "bundled Mini catalog is invalid"
    end

    def research_document(input)
      require_object!(input)
      allowed = %w[work_id version]
      raise Error, "research document input contains unknown fields" unless (input.keys - allowed).empty?
      work_id = input["work_id"]
      version = input.fetch("version", "latest")
      raise Error, "research work ID is invalid" unless work_id.is_a?(String) && UUID.match?(work_id)
      unless version.is_a?(String) && (version == "latest" || UUID.match?(version))
        raise Error, "research version is invalid"
      end
      run_research_library("取件", "--work-id", work_id, "--version", version, "--artifact", "original")
    end

    def research_artifact(input)
      require_object!(input)
      allowed = %w[artifact_id expected_sha256]
      raise Error, "research artifact input contains unknown fields" unless (input.keys - allowed).empty?
      artifact_id = input["artifact_id"]
      expected_sha256 = input["expected_sha256"]
      raise Error, "research artifact ID is invalid" unless artifact_id.is_a?(String) && UUID.match?(artifact_id)
      unless expected_sha256.is_a?(String) && SHA256.match?(expected_sha256)
        raise Error, "research artifact digest is invalid"
      end
      run_research_library(
        "精确取件", "--artifact-id", artifact_id, "--expected-sha256", expected_sha256
      )
    end

    def run_research_library(command, *arguments)
      explicit_root = ENV["TWO_HEAD_WU_RESEARCH_LIBRARY_ROOT"].to_s
      if explicit_root.empty?
        executable = @source_root.join("core/bin/wu")
        command_arguments = ["资料库", command, *arguments, "--json"]
      else
        data_root = Pathname.new(explicit_root).expand_path.cleanpath
        raise Error, "Mini research library provider is unavailable" unless data_root.absolute?
        marker = JSON.parse(data_root.join(".research-library-root.json").read(encoding: "UTF-8"))
        if marker["member_index_snapshot"] == true
          executable = @source_root.join("capabilities/remote-work/worker/member-research-library")
          direct_command = {
            "状态" => "status", "搜索" => "search", "取件" => "get"
          }.fetch(command) { raise Error, "Mini research library provider is unavailable" }
        else
          executable = @source_root.join("capabilities/research-library/adapters/research-library")
          direct_command = {
            "状态" => "status", "搜索" => "search", "取件" => "get", "精确取件" => "get-artifact"
          }.fetch(command) { raise Error, "Mini research library provider is unavailable" }
        end
        command_arguments = ["--data-root", data_root.to_s, direct_command, *arguments, "--json"]
      end
      raise Error, "Mini research library provider is unavailable" unless executable.file? && executable.executable?
      stdout = stderr = status = nil
      Timeout.timeout(60) do
        stdout, stderr, status = Open3.capture3(
          { "PYTHONDONTWRITEBYTECODE" => "1" },
          executable.to_s, *command_arguments,
          chdir: @source_root.to_s
        )
      end
      raise Error, "Mini research library provider is unavailable" unless status&.success?
      payload = JSON.parse(stdout)
      unless payload.is_a?(Hash) && payload["ok"] == true && payload["data"].is_a?(Hash)
        raise Error, "Mini research library provider returned an invalid result"
      end
      payload.fetch("data")
    rescue JSON::ParserError, Timeout::Error, Errno::EACCES, Errno::ENOENT
      raise Error, "Mini research library provider is unavailable"
    end

    def safe_research_result(item)
      raise Error, "Mini research search returned invalid data" unless item.is_a?(Hash)
      allowed = %w[
        work_id version_id artifact_id canonical_title kind language publication_date version_kind doi role sha256
        mime locator_fragment score score_source creators available_artifacts
      ]
      item.slice(*allowed).tap do |result|
        raise Error, "Mini research search result has invalid identity" unless UUID.match?(result["work_id"].to_s) && UUID.match?(result["version_id"].to_s)
        result["locator_fragment"] = result["locator_fragment"].to_s[0, 2000]
      end
    end

    def safe_research_document(document)
      raise Error, "Mini research document returned invalid data" unless document.is_a?(Hash)
      allowed = %w[
        id work_id version_id role sha256 mime bytes language generator quality_status authoritative created_at
        canonical_title kind publication_date version_kind doi publisher journal volume issue pages creators
      ]
      document.slice(*allowed).merge(
        "export_available" => document["bytes"].is_a?(Integer) && document["bytes"].between?(1, MAX_ARTIFACT_BYTES),
        "citation_authority" => document["authoritative"] == 1 ? "original" : "non-authoritative"
      ).tap do |result|
        valid = UUID.match?(result["work_id"].to_s) && UUID.match?(result["version_id"].to_s) &&
                SHA256.match?(result["sha256"].to_s)
        raise Error, "Mini research document has invalid identity" unless valid
      end
    end

    def require_object!(value)
      raise Error, "capability input must be an object" unless value.is_a?(Hash)
    end

    def safe_resource_actions(value)
      Array(value).map(&:to_s).reject { |action| action.match?(/ssh|credential|secret|password|token/i) }
    end

    def openai_docs_arguments(action, input)
      allowed = {
        "search" => %w[action query limit cursor],
        "list" => %w[action limit cursor],
        "fetch" => %w[action url anchor],
        "list-api-endpoints" => %w[action],
        "get-openapi-spec" => %w[action url languages code_examples_only]
      }.fetch(action)
      unknown = input.keys - allowed
      raise Error, "OpenAI Docs input contains fields unavailable for this action" unless unknown.empty?

      arguments = {}
      if action == "search"
        query = input["query"]
        raise Error, "OpenAI Docs search query is required" unless query.is_a?(String) && query.length.between?(1, 2000)
        arguments["query"] = query
      end
      if %w[search list].include?(action) && input.key?("limit")
        limit = input["limit"]
        raise Error, "OpenAI Docs limit must be between 1 and 50" unless limit.is_a?(Integer) && limit.between?(1, 50)
        arguments["limit"] = limit
      end
      if %w[search list].include?(action) && input.key?("cursor")
        cursor = input["cursor"]
        raise Error, "OpenAI Docs cursor is invalid" unless cursor.is_a?(String) && cursor.length.between?(1, 1024)
        arguments["cursor"] = cursor
      end
      if %w[fetch get-openapi-spec].include?(action)
        url = input["url"]
        raise Error, "OpenAI Docs URL is invalid" unless url.is_a?(String) && url.length.between?(1, 2000) && SAFE_DOC_URL.match?(url)
        arguments["url"] = url
      end
      if action == "fetch" && input.key?("anchor")
        anchor = input["anchor"]
        raise Error, "OpenAI Docs anchor is invalid" unless anchor.is_a?(String) && anchor.length.between?(1, 512)
        arguments["anchor"] = anchor
      end
      if action == "get-openapi-spec" && input.key?("languages")
        languages = input["languages"]
        valid = languages.is_a?(Array) && languages.length <= 10 &&
                languages.all? { |item| item.is_a?(String) && item.match?(/\A[A-Za-z0-9_+.-]{1,32}\z/) }
        raise Error, "OpenAI Docs languages are invalid" unless valid
        arguments["languages"] = languages
      end
      if action == "get-openapi-spec" && input.key?("code_examples_only")
        value = input["code_examples_only"]
        raise Error, "OpenAI Docs code_examples_only must be boolean" unless value == true || value == false
        arguments["codeExamplesOnly"] = value
      end
      arguments
    end

    def mcp_request(method, params)
      uri = URI(MCP_ENDPOINT)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 10
      http.read_timeout = 45
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request["Accept"] = "application/json, text/event-stream"
      request["MCP-Protocol-Version"] = MCP_PROTOCOL_VERSION
      request["User-Agent"] = "two-head-wu-remote/#{@version}"
      request.body = JSON.generate({ "jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params })
      response = http.request(request)
      raise Error, "OpenAI Docs MCP is unavailable" unless response.is_a?(Net::HTTPSuccess)
      raise Error, "OpenAI Docs MCP response is too large" if response.body.to_s.bytesize > MAX_MCP_RESPONSE_BYTES

      payload = parse_mcp_body(response.body.to_s, response["content-type"])
      raise Error, "OpenAI Docs MCP returned a protocol error" if payload["error"]
      payload.fetch("result")
    rescue JSON::ParserError, KeyError, URI::InvalidURIError,
           Net::OpenTimeout, Net::ReadTimeout, SocketError, SystemCallError
      raise Error, "OpenAI Docs MCP is unavailable"
    end

    def parse_mcp_body(body, content_type)
      return JSON.parse(body) unless content_type.to_s.include?("text/event-stream")

      data = body.lines.map do |line|
        line.start_with?("data:") ? line.delete_prefix("data:").strip : nil
      end.compact.reject { |line| line.empty? || line == "[DONE]" }
      raise Error, "OpenAI Docs MCP returned an empty event stream" if data.empty?
      JSON.parse(data.first)
    end

    def workflow_execution_root(adapter)
      case adapter.fetch("capability_id")
      when "workflow:remote-work-health" then @runtime_root
      when "workflow:sync-air" then @pipeline_root
      else @source_root
      end
    end

    def source_execution_probe(path, root: @runtime_root)
      environment = { "LANG" => "en_US.UTF-8", "LC_ALL" => "en_US.UTF-8" }
      _stdout, _stderr, status = Open3.capture3(
        environment,
        "/usr/bin/ruby", "-e", "File.open(ARGV.fetch(0), 'rb') { |file| file.read(1) }", path.to_s,
        chdir: root.to_s
      )
      status.success?
    rescue Errno::EACCES, Errno::ENOENT
      false
    end

    def validate_workflow_command!(command, execution_root)
      valid = command.length.between?(1, 12) && command.all? do |item|
        item.is_a?(String) && item.length.between?(1, 512) && !item.include?("\0")
      end
      raise Error, "registered workflow command is invalid" unless valid
      executable = Pathname.new(command.first)
      raise Error, "registered workflow executable must be project-relative" if executable.absolute? || executable.each_filename.include?("..")
      resolved = execution_root.join(executable).cleanpath
      prefix = execution_root.to_s + File::SEPARATOR
      raise Error, "registered workflow executable escaped the project" unless resolved.to_s.start_with?(prefix) && resolved.file?
    end

    def sanitize_workflow_output(value)
      text = value.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
      text = text.gsub(@source_root.to_s, "<two-head-wu>").gsub(@runtime_root.to_s, "<runtime>").gsub(Dir.home, "<home>")
      text.byteslice(0, MAX_WORKFLOW_OUTPUT_BYTES).to_s
    end
  end
end
