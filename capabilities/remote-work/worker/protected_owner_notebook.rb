# frozen_string_literal: true

require "json"
require "open3"
require "pathname"
require "time"
require "timeout"

module RemoteWork
  # The low-privilege Air worker may ask this root-owned helper to perform only
  # the four explicit notebook operations. The helper drops to the registered
  # owner account before starting the separately installed personal-memory
  # adapter; it never accepts a command, path, environment variable, or config
  # location from the job payload.
  class ProtectedOwnerNotebook
    DEFAULT_CONFIG = Pathname.new("/Library/TwoHeadedWu/private/owner-adapters/notebook.json")
    MAX_REQUEST_BYTES = 16 * 1024
    MAX_OUTPUT_BYTES = 1024 * 1024
    RECORD_ID = /\Apm-[0-9]{8}T[0-9]{6}-[0-9a-f]{8}\z/.freeze
    LABEL = /\A[a-z0-9][a-z0-9-]{0,39}\z/.freeze
    CATEGORIES = %w[identity preference project decision fact].freeze
    CONFIG_KEYS = %w[
      schema_version owner_uid owner_gid owner_home personal_memory_adapter
      openclaw_bin memory_workspace
    ].freeze

    def initialize(config_path: DEFAULT_CONFIG, input: $stdin, output: $stdout, error: $stderr, runner: nil)
      @config_path = Pathname.new(config_path)
      @input = input
      @output = output
      @error = error
      @runner = runner
    end

    def run(require_root: true)
      raise "protected notebook helper must run as root" if require_root && !Process.euid.zero?

      request = parse_request
      config = load_config
      arguments, stdin_data = invocation(request)
      stdout, status = execute_adapter(config, arguments, stdin_data)
      payload = JSON.parse(stdout)
      @output.write(JSON.generate(project_output(request.fetch("action"), payload)) + "\n")
      status.success? ? 0 : 2
    rescue JSON::ParserError, KeyError, ArgumentError, SystemCallError, Timeout::Error, RuntimeError => exception
      @error.puts("Error: #{safe_error(exception)}")
      2
    end

    def invocation(request)
      object!(request, "notebook request")
      action = request["action"]
      raise "notebook action is unavailable" unless %w[recall remember correct forget].include?(action)

      case action
      when "recall"
        exact_keys!(request, %w[action query max_results], required: %w[action query])
        query = bounded_text(request["query"], "notebook query", maximum: 500)
        maximum = request.fetch("max_results", 3)
        raise "notebook result limit is invalid" unless maximum.is_a?(Integer) && maximum.between?(1, 5)
        [["recall", "--scope", "notebook", "--query", query, "--max-results", maximum.to_s], ""]
      when "remember"
        exact_keys!(request, %w[action text category project_id], required: %w[action text])
        text = bounded_text(request["text"], "notebook text", maximum: 2_000)
        category = request.fetch("category", "fact")
        raise "notebook category is invalid" unless CATEGORIES.include?(category)
        arguments = ["remember", "--category", category, "--source", "owner-air"]
        project_id = request["project_id"]
        if project_id
          raise "notebook project id is invalid" unless project_id.is_a?(String) && LABEL.match?(project_id)
          arguments.concat(["--project-id", project_id])
        end
        [arguments, text]
      when "correct"
        exact_keys!(request, %w[action record_id text], required: %w[action record_id text])
        record_id = record_id!(request["record_id"])
        text = bounded_text(request["text"], "notebook text", maximum: 2_000)
        [["correct", "--id", record_id], text]
      when "forget"
        exact_keys!(request, %w[action record_id], required: %w[action record_id])
        [["forget", "--id", record_id!(request["record_id"])], ""]
      end
    end

    def project_output(action, payload)
      object!(payload, "personal-memory result")
      expected = "two-head-wu.personal-memory.#{action}.v1"
      raise "personal-memory result schema is invalid" unless payload["schema"] == expected

      result = case action
               when "recall"
                 raise "personal-memory recall escaped notebook scope" unless payload["scope"] == "notebook"
                 records = Array(payload["results"]).first(5).map { |item| safe_record(item) }
                 { "query" => bounded_text(payload["query"], "result query", maximum: 500), "results" => records }
               when "remember"
                 {
                   "id" => record_id!(payload["id"]),
                   "stored" => payload["stored"] == true,
                   "category" => category!(payload["category"]),
                   "project_id" => optional_label(payload["project_id"])
                 }.compact
               when "correct"
                 { "id" => record_id!(payload["id"]), "corrected" => payload["corrected"] == true }
               when "forget"
                 { "id" => record_id!(payload["id"]), "forgotten" => payload["forgotten"] == true }
               else
                 raise "notebook action is unavailable"
               end
      {
        "schema" => "two-head-wu.personal-memory.owner-air.v1",
        "action" => action,
        "observed_at" => Time.now.utc.iso8601,
        "result" => result
      }
    end

    private

    def parse_request
      raw = @input.read(MAX_REQUEST_BYTES + 1)
      raise "notebook request is too large" if raw.bytesize > MAX_REQUEST_BYTES
      value = JSON.parse(raw)
      object!(value, "notebook request")
      value
    end

    def load_config
      clean = @config_path.expand_path.cleanpath
      stat = clean.lstat
      unless clean.absolute? && stat.file? && !stat.symlink? && stat.uid.zero? && (stat.mode & 0o777) == 0o600
        raise "protected notebook config is unavailable"
      end
      config = JSON.parse(clean.read(encoding: "UTF-8"))
      object!(config, "protected notebook config")
      exact_keys!(config, CONFIG_KEYS, required: CONFIG_KEYS)
      raise "protected notebook config schema is invalid" unless config["schema_version"] == 1
      %w[owner_uid owner_gid].each do |key|
        value = config[key]
        raise "protected notebook identity is invalid" unless value.is_a?(Integer) && value.positive?
      end
      %w[owner_home personal_memory_adapter openclaw_bin memory_workspace].each do |key|
        config[key] = exact_absolute_path(config[key], key)
      end
      raise "protected notebook owner home is unavailable" unless config["owner_home"].directory?
      raise "protected notebook workspace is unavailable" unless config["memory_workspace"].directory?
      %w[personal_memory_adapter openclaw_bin].each do |key|
        path = config[key]
        raise "protected notebook executable is unavailable" unless path.file? && path.executable?
      end
      config
    end

    def execute_adapter(config, arguments, stdin_data)
      return @runner.call(config, arguments, stdin_data) if @runner

      environment = {
        "HOME" => config.fetch("owner_home").to_s,
        "LANG" => "en_US.UTF-8",
        "LC_ALL" => "en_US.UTF-8",
        "PATH" => "/usr/bin:/bin:/usr/sbin:/sbin",
        "TWO_HEAD_WU_OPENCLAW_BIN" => config.fetch("openclaw_bin").to_s,
        "TWO_HEAD_WU_MEMORY_WORKSPACE" => config.fetch("memory_workspace").to_s
      }
      stdout = stderr = status = nil
      Timeout.timeout(90) do
        stdout, stderr, status = Open3.capture3(
          environment,
          config.fetch("personal_memory_adapter").to_s,
          *arguments,
          stdin_data: stdin_data,
          unsetenv_others: true,
          uid: config.fetch("owner_uid"),
          gid: config.fetch("owner_gid"),
          chdir: config.fetch("owner_home").to_s
        )
      end
      raise "personal-memory adapter failed" unless status&.success?
      raise "personal-memory result is too large" if stdout.bytesize > MAX_OUTPUT_BYTES
      [stdout, status]
    end

    def safe_record(value)
      object!(value, "notebook result record")
      record = {
        "id" => record_id!(value["id"]),
        "category" => category!(value["category"]),
        "fact" => bounded_text(value["fact"], "notebook fact", maximum: 2_000)
      }
      record["project_id"] = optional_label(value["project_id"]) if value.key?("project_id")
      score = value["score"]
      record["score"] = score if score.is_a?(Numeric) && score.finite?
      record
    end

    def exact_absolute_path(value, label)
      path = Pathname.new(value.to_s)
      raise "#{label.tr('_', ' ')} is invalid" unless path.absolute? && path.cleanpath == path
      real = path.realpath
      raise "#{label.tr('_', ' ')} may not use symbolic links" unless real == path
      real
    end

    def exact_keys!(value, allowed, required:)
      keys = value.keys
      raise "object contains unknown fields" unless (keys - allowed).empty?
      raise "object is missing required fields" unless (required - keys).empty?
    end

    def object!(value, label)
      raise "#{label} must be an object" unless value.is_a?(Hash) && value.keys.all? { |key| key.is_a?(String) }
    end

    def bounded_text(value, label, maximum:)
      raise "#{label} is invalid" unless value.is_a?(String)
      text = value.encode("UTF-8", invalid: :replace, undef: :replace, replace: "").strip
      raise "#{label} is invalid" unless text.length.between?(1, maximum)
      text
    end

    def record_id!(value)
      raise "notebook record id is invalid" unless value.is_a?(String) && RECORD_ID.match?(value)
      value
    end

    def category!(value)
      raise "notebook category is invalid" unless CATEGORIES.include?(value)
      value
    end

    def optional_label(value)
      return nil if value.nil?
      raise "notebook project id is invalid" unless value.is_a?(String) && LABEL.match?(value)
      value
    end

    def safe_error(exception)
      allowed = exception.message.to_s
      return allowed if allowed.match?(/\A(?:notebook|personal-memory|protected notebook|object|result query)/)
      "protected notebook request failed"
    end
  end
end

if $PROGRAM_NAME == __FILE__
  exit RemoteWork::ProtectedOwnerNotebook.new.run
end
