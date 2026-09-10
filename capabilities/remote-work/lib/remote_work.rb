#!/usr/bin/env ruby
# frozen_string_literal: true

require "base64"
require "digest"
require "fileutils"
require "find"
require "json"
require "net/http"
require "open3"
require "openssl"
require "pathname"
require "securerandom"
require "time"
require "tmpdir"
require "uri"
require "zlib"
require "rubygems/package"

module RemoteWork
  VERSION = "0.12.0"
  PROTOCOL_VERSION = 2
  KEYCHAIN_SERVICE = "com.twoheadwu.remote-work"
  DEFAULT_API_PREFIX = "/two-head-wu/v1"
  REQUEST_WINDOW = 300

  class Error < StandardError; end

  class CodexStatusFormatter
    def initialize(output)
      @output = output
    end

    def render
      accounts = Array(@output["accounts"])
      lines = [
        "Codex 账户额度",
        "来源：#{@output.fetch('source_device', 'mac-mini-worker')} ｜ 观测：#{format_observed_at(@output['observed_at'])}",
        "─" * 64
      ]
      accounts.each_with_index do |item, index|
        account = item["account"] || {}
        lines << "#{item.fetch('identity')} · #{account.fetch('plan_type', '-')} · #{account.fetch('email', '未登录/未知')}"
        if item["status"] == "ok"
          lines << quota_window_line("5 小时", quota_window(item, "five_hour", 300))
          lines << quota_window_line("7 天", quota_window(item, "weekly", 10_080))
        elsif item["status"] == "not-logged-in"
          lines << "  状态    未登录"
        else
          lines << "  状态    查询失败"
        end
        lines << "─" * 64 if index < accounts.length - 1
      end
      lines.join("\n") + "\n"
    end

    private

    def quota_window(item, explicit_key, duration_mins)
      explicit = item[explicit_key]
      return explicit if explicit.is_a?(Hash)

      Array(item["rate_limits"]).each do |bucket|
        %w[primary secondary].each do |key|
          window = bucket[key]
          return window if window.is_a?(Hash) && window["window_duration_mins"] == duration_mins
        end
      end
      nil
    end

    def quota_window_line(label, window)
      label_text = label == "5 小时" ? "5 小时" : "7 天  "
      return "  #{label_text}  [----------]     未返回  重置 -" unless window.is_a?(Hash)

      remaining = window["remaining_percent"]
      remaining_text = remaining.is_a?(Numeric) ? format("%.1f%%", remaining).sub(".0%", "%") : "未返回"
      reset = window["resets_at"]
      reset_text = reset.is_a?(Numeric) ? Time.at(reset).getlocal.strftime("%m/%d %H:%M") : "-"
      format("  %s  %s  %6s  重置 %s", label_text, quota_bar(remaining), remaining_text, reset_text)
    rescue RangeError
      format("  %s  %s  %6s  重置 %s", label_text, quota_bar(remaining), remaining_text, "-")
    end

    def quota_bar(remaining)
      return "[----------]" unless remaining.is_a?(Numeric)

      bounded = [[remaining.to_f, 0.0].max, 100.0].min
      filled = (bounded / 10.0).round
      "[#{'█' * filled}#{'░' * (10 - filled)}]"
    end

    def format_observed_at(value)
      return "-" if value.to_s.empty?

      Time.iso8601(value.to_s).getlocal.strftime("%Y-%m-%d %H:%M:%S")
    rescue ArgumentError
      value.to_s
    end
  end

  module ReleaseSignature
    SIGNED_FIELDS = %w[schema_version release_id version channel sha256 size generated_at public_key_sha256].freeze
    RELEASE_ID = /\Av[0-9]+\.[0-9]+\.[0-9]+-[a-f0-9]{12}\z/.freeze
    module_function

    def canonical(manifest)
      values = SIGNED_FIELDS.each_with_object({}) do |key, result|
        raise Error, "发布清单缺少字段：#{key}" unless manifest.key?(key)
        result[key] = manifest[key]
      end
      JSON.generate(values)
    end

    def sign(manifest, private_pem)
      key = OpenSSL::PKey::RSA.new(private_pem)
      Base64.strict_encode64(key.sign(OpenSSL::Digest::SHA256.new, canonical(manifest)))
    rescue OpenSSL::PKey::PKeyError
      raise Error, "客户端发布签名私钥无效"
    end

    def verify!(manifest, public_pem)
      raise Error, "客户端发布清单版本不受支持" unless manifest["schema_version"] == 2
      raise Error, "客户端发布 ID 无效" unless RELEASE_ID.match?(manifest["release_id"].to_s)
      raise Error, "客户端发布通道无效" unless %w[stable dev].include?(manifest["channel"])
      raise Error, "客户端发布哈希无效" unless manifest["sha256"].to_s.match?(/\A[a-f0-9]{64}\z/)
      raise Error, "客户端发布大小无效" unless manifest["size"].is_a?(Integer) && manifest["size"].positive?
      key = OpenSSL::PKey::RSA.new(public_pem)
      fingerprint = Digest::SHA256.hexdigest(key.public_key.to_der)
      raise Error, "客户端发布公钥指纹不匹配" unless secure_equal?(fingerprint, manifest["public_key_sha256"].to_s)
      signature = Base64.strict_decode64(manifest.fetch("signature_base64"))
      valid = key.verify(OpenSSL::Digest::SHA256.new, signature, canonical(manifest))
      raise Error, "客户端发布签名验证失败" unless valid
      true
    rescue ArgumentError, KeyError, OpenSSL::PKey::PKeyError
      raise Error, "客户端发布签名无效"
    end

    def secure_equal?(first, second)
      return false unless first.bytesize == second.bytesize
      difference = 0
      first.bytes.zip(second.bytes) { |left, right| difference |= left ^ right }
      difference.zero?
    end
  end

  module ModuleSignature
    FIELDS = %w[schema_version generated_at modules public_key_sha256].freeze
    module_function

    def canonical(manifest)
      JSON.generate(FIELDS.each_with_object({}) { |field, output| output[field] = manifest.fetch(field) })
    end

    def sign(manifest, private_key)
      key = OpenSSL::PKey::RSA.new(private_key)
      Base64.strict_encode64(key.sign(OpenSSL::Digest::SHA256.new, canonical(manifest)))
    rescue OpenSSL::PKey::PKeyError => error
      raise Error, "组件签名密钥无效：#{error.class}"
    end

    def verify!(manifest, public_key_text)
      raise Error, "组件清单格式不受支持" unless manifest.fetch("schema_version") == 2
      key = OpenSSL::PKey::RSA.new(public_key_text)
      fingerprint = Digest::SHA256.hexdigest(key.public_key.to_der)
      raise Error, "组件清单发布公钥不匹配" unless secure_equal?(fingerprint, manifest.fetch("public_key_sha256"))
      signature = Base64.strict_decode64(manifest.fetch("signature_base64"))
      valid = key.verify(OpenSSL::Digest::SHA256.new, signature, canonical(manifest))
      raise Error, "组件清单签名无效" unless valid
      true
    rescue KeyError, ArgumentError, OpenSSL::PKey::PKeyError => error
      raise Error, "组件清单签名无效：#{error.class}"
    end

    def secure_equal?(first, second)
      return false unless first.bytesize == second.bytesize
      difference = 0
      first.bytes.zip(second.bytes) { |left, right| difference |= left ^ right }
      difference.zero?
    end
  end

  module CapabilityCatalogSignature
    FIELDS = %w[schema_version catalog_version generated_at capabilities public_key_sha256].freeze
    CATALOG_VERSION = /\A[a-f0-9]{16}\z/.freeze
    CAPABILITY_ID = /\A[a-z][a-z0-9-]*:[a-z][a-z0-9-]*\z/.freeze
    KINDS = %w[artifact capability codex-task database-query mcp-tool memory model-catalog skill tool workflow].freeze
    LOCATIONS = %w[air mac-mini aliyun].freeze
    EXPOSURES = %w[callable metadata-only].freeze
    INVOCATION_POLICIES = %w[auto queue confirm manual unavailable].freeze
    SIDE_EFFECTS = %w[read-only local-write isolated-write external-write destructive metadata-only].freeze
    STATUSES = %w[active disabled].freeze
    EXECUTOR_KINDS = %w[tool workflow codex].freeze
    REPLAY_CLASSES = %w[safe-read idempotent-write owner-confirmation-required].freeze
    APPROVAL_POLICIES = %w[auto owner-confirmation manual].freeze
    AUDIENCES = %w[all-air owner-air owner-step-up].freeze
    CONFIRMATIONS = %w[none owner-password].freeze
    EXECUTORS = %w[air-worker protected-adapter].freeze
    module_function

    def canonical(manifest)
      JSON.generate(FIELDS.each_with_object({}) { |field, output| output[field] = manifest.fetch(field) })
    end

    def sign(manifest, private_key)
      key = OpenSSL::PKey::RSA.new(private_key)
      Base64.strict_encode64(key.sign(OpenSSL::Digest::SHA256.new, canonical(manifest)))
    rescue OpenSSL::PKey::PKeyError => error
      raise Error, "能力目录签名密钥无效：#{error.class}"
    end

    def verify!(manifest, public_key_text)
      raise Error, "能力目录格式不受支持" unless manifest.fetch("schema_version") == 1
      raise Error, "能力目录版本无效" unless CATALOG_VERSION.match?(manifest.fetch("catalog_version").to_s)
      capabilities = manifest.fetch("capabilities")
      raise Error, "能力目录条目无效" unless capabilities.is_a?(Array) && capabilities.length <= 256
      capabilities.each { |entry| validate_entry!(entry) }
      ids = capabilities.map { |entry| entry.fetch("id") }
      raise Error, "能力目录包含重复 ID" unless ids.uniq.length == ids.length
      key = OpenSSL::PKey::RSA.new(public_key_text)
      fingerprint = Digest::SHA256.hexdigest(key.public_key.to_der)
      raise Error, "能力目录发布公钥不匹配" unless secure_equal?(fingerprint, manifest.fetch("public_key_sha256"))
      signature = Base64.strict_decode64(manifest.fetch("signature_base64"))
      valid = key.verify(OpenSSL::Digest::SHA256.new, signature, canonical(manifest))
      raise Error, "能力目录签名无效" unless valid
      true
    rescue KeyError, ArgumentError, OpenSSL::PKey::PKeyError => error
      raise Error, "能力目录签名无效：#{error.class}"
    end

    def validate_entry!(entry)
      raise Error, "能力目录条目无效" unless entry.is_a?(Hash)
      raise Error, "能力目录 ID 无效" unless CAPABILITY_ID.match?(entry.fetch("id").to_s)
      raise Error, "能力目录类型无效" unless KINDS.include?(entry.fetch("kind"))
      raise Error, "能力目录位置无效" unless LOCATIONS.include?(entry.fetch("location"))
      raise Error, "能力目录暴露级别无效" unless EXPOSURES.include?(entry.fetch("exposure"))
      raise Error, "能力目录调用策略无效" unless INVOCATION_POLICIES.include?(entry.fetch("invocation_policy"))
      raise Error, "能力目录副作用无效" unless SIDE_EFFECTS.include?(entry.fetch("side_effect"))
      raise Error, "能力目录状态无效" unless STATUSES.include?(entry.fetch("status"))
      if entry.key?("name")
        raise Error, "能力目录名称无效" unless entry["name"].is_a?(String) && !entry["name"].empty? && entry["name"].length <= 160 && !entry["name"].include?("\0")
      end
      raise Error, "能力目录摘要无效" unless entry.fetch("summary").is_a?(String) && !entry.fetch("summary").empty?
      raise Error, "能力目录 queueable 无效" unless [true, false].include?(entry.fetch("queueable"))
      requirements = entry.fetch("runtime_requires", [])
      valid_requirements = requirements.is_a?(Array) && requirements.length <= 32 && requirements.all? do |value|
        value.is_a?(String) && value.match?(/\A[a-z][a-z0-9-]{0,63}\z/)
      end
      raise Error, "能力目录运行要求无效" unless valid_requirements
      if entry.key?("executor_kind")
        raise Error, "能力目录执行器类型无效" unless EXECUTOR_KINDS.include?(entry["executor_kind"])
      end
      if entry.key?("adapter")
        raise Error, "能力目录适配器无效" unless CAPABILITY_ID.match?(entry["adapter"].to_s)
      end
      if entry.key?("capability_version")
        raise Error, "能力目录版本无效" unless entry["capability_version"].is_a?(Integer) && entry["capability_version"].positive?
      end
      if entry.key?("audience")
        raise Error, "能力目录受众无效" unless AUDIENCES.include?(entry["audience"])
      end
      if entry.key?("confirmation")
        raise Error, "能力目录二次确认无效" unless CONFIRMATIONS.include?(entry["confirmation"])
      end
      if entry.key?("executor")
        raise Error, "能力目录执行边界无效" unless EXECUTORS.include?(entry["executor"])
      end
      if entry.key?("replay_class")
        raise Error, "能力目录重放类别无效" unless REPLAY_CLASSES.include?(entry["replay_class"])
      end
      if entry.key?("approval_policy")
        raise Error, "能力目录确认策略无效" unless APPROVAL_POLICIES.include?(entry["approval_policy"])
      end
      true
    end

    def secure_equal?(first, second)
      return false unless first.bytesize == second.bytesize
      difference = 0
      first.bytes.zip(second.bytes) { |left, right| difference |= left ^ right }
      difference.zero?
    end
  end

  module CapabilityInventorySignature
    FIELDS = %w[schema_version inventory_version generated_at source_device entries public_key_sha256].freeze
    INVENTORY_VERSION = /\A[a-f0-9]{16}\z/.freeze
    ITEM_ID = /\A(?:skill|package|agent|mcp|runtime|workflow|resource):[a-z][a-z0-9-]*\z/.freeze
    KINDS = %w[skill capability-package agent mcp-server runtime workflow resource].freeze
    AIR_MODES = %w[local portable remote-auto remote-queue confirm metadata-only unavailable].freeze
    LOCATIONS = %w[air mac-mini aliyun external].freeze
    OPTIONAL_FIELDS = %w[version native_status category callable_via].freeze
    module_function

    def canonical(manifest)
      JSON.generate(FIELDS.each_with_object({}) { |field, output| output[field] = manifest.fetch(field) })
    end

    def sign(manifest, private_key)
      key = OpenSSL::PKey::RSA.new(private_key)
      Base64.strict_encode64(key.sign(OpenSSL::Digest::SHA256.new, canonical(manifest)))
    rescue OpenSSL::PKey::PKeyError => error
      raise Error, "Mini 功能表签名密钥无效：#{error.class}"
    end

    def verify!(manifest, public_key_text)
      raise Error, "Mini 功能表格式不受支持" unless manifest.fetch("schema_version") == 1
      raise Error, "Mini 功能表版本无效" unless INVENTORY_VERSION.match?(manifest.fetch("inventory_version").to_s)
      raise Error, "Mini 功能表来源无效" unless manifest.fetch("source_device") == "mac-mini"
      entries = manifest.fetch("entries")
      raise Error, "Mini 功能表条目无效" unless entries.is_a?(Array) && entries.length <= 512
      entries.each { |entry| validate_entry!(entry) }
      ids = entries.map { |entry| entry.fetch("id") }
      raise Error, "Mini 功能表包含重复 ID" unless ids.uniq.length == ids.length
      key = OpenSSL::PKey::RSA.new(public_key_text)
      fingerprint = Digest::SHA256.hexdigest(key.public_key.to_der)
      raise Error, "Mini 功能表发布公钥不匹配" unless secure_equal?(fingerprint, manifest.fetch("public_key_sha256"))
      signature = Base64.strict_decode64(manifest.fetch("signature_base64"))
      valid = key.verify(OpenSSL::Digest::SHA256.new, signature, canonical(manifest))
      raise Error, "Mini 功能表签名无效" unless valid
      true
    rescue KeyError, ArgumentError, OpenSSL::PKey::PKeyError => error
      raise Error, "Mini 功能表签名无效：#{error.class}"
    end

    def validate_entry!(entry)
      raise Error, "Mini 功能表条目无效" unless entry.is_a?(Hash)
      allowed = %w[id kind name summary status air_mode location] + OPTIONAL_FIELDS
      raise Error, "Mini 功能表包含未允许字段" unless (entry.keys - allowed).empty?
      raise Error, "Mini 功能表 ID 无效" unless ITEM_ID.match?(entry.fetch("id").to_s)
      raise Error, "Mini 功能表类型无效" unless KINDS.include?(entry.fetch("kind"))
      raise Error, "Mini 功能表名称无效" unless safe_text?(entry.fetch("name"), 160)
      raise Error, "Mini 功能表说明无效" unless safe_text?(entry.fetch("summary"), 1000)
      raise Error, "Mini 功能表状态无效" unless entry.fetch("status").to_s.match?(/\A[a-z][a-z0-9-]{0,63}\z/)
      raise Error, "Mini 功能表 Air 模式无效" unless AIR_MODES.include?(entry.fetch("air_mode"))
      raise Error, "Mini 功能表位置无效" unless LOCATIONS.include?(entry.fetch("location"))
      %w[version native_status category].each do |field|
        raise Error, "Mini 功能表可选字段无效" if entry.key?(field) && !safe_text?(entry[field], 160)
      end
      if entry.key?("callable_via")
        raise Error, "Mini 功能表调用入口无效" unless CapabilityCatalogSignature::CAPABILITY_ID.match?(entry["callable_via"].to_s)
      end
      true
    end

    def safe_text?(value, maximum)
      value.is_a?(String) && !value.empty? && value.length <= maximum && !value.include?("\0")
    end

    def secure_equal?(first, second)
      return false unless first.bytesize == second.bytesize
      difference = 0
      first.bytes.zip(second.bytes) { |left, right| difference |= left ^ right }
      difference.zero?
    end
  end

  module Atomic
    module_function

    def write(path, content, mode: 0o600)
      target = Pathname.new(path)
      FileUtils.mkdir_p(target.dirname.to_s, mode: 0o700)
      temporary = target.dirname.join(".#{target.basename}.#{Process.pid}.#{SecureRandom.hex(4)}")
      File.open(temporary.to_s, File::WRONLY | File::CREAT | File::EXCL, mode) do |file|
        file.write(content)
        file.flush
        file.fsync
      end
      File.chmod(mode, temporary.to_s)
      File.rename(temporary.to_s, target.to_s)
    ensure
      FileUtils.rm_f(temporary.to_s) if defined?(temporary) && temporary
    end

    def json(path, value, mode: 0o600)
      write(path, JSON.pretty_generate(value) + "\n", mode: mode)
    end
  end

  class Config
    attr_reader :home

    def initialize(home = nil)
      configured = home || ENV["WU_REMOTE_HOME"]
      @home = Pathname.new(configured && !configured.empty? ? configured : File.join(Dir.home, ".config", "two-head-wu", "remote-work")).expand_path
    end

    def path
      home.join("config.json")
    end

    def state_path
      home.join("state.json")
    end

    def load
      raise Error, "客户端尚未配置；请运行安装脚本或 wu remote enroll" unless path.file?

      value = JSON.parse(path.read(encoding: "UTF-8"))
      raise Error, "客户端配置版本不受支持" unless value["schema_version"] == 1
      validate_endpoint!(value.fetch("endpoint"))
      value
    rescue JSON::ParserError, KeyError => error
      raise Error, "客户端配置无效：#{error.message}"
    end

    def configured?
      path.file?
    end

    def save(value)
      data = value.merge("schema_version" => 1, "updated_at" => Time.now.utc.iso8601)
      validate_endpoint!(data.fetch("endpoint"))
      Atomic.json(path, data)
    end

    def state
      return default_state unless state_path.file?

      JSON.parse(state_path.read(encoding: "UTF-8"))
    rescue JSON::ParserError
      raise Error, "客户端状态文件无效"
    end

    def save_state(value)
      Atomic.json(state_path, value.merge("schema_version" => 1, "updated_at" => Time.now.utc.iso8601))
    end

    def secret(device_id = nil)
      value = ENV["WU_REMOTE_DEVICE_SECRET"].to_s
      return value unless value.empty?

      config = load
      device = device_id || config.fetch("device_id")
      if config["secret_store"] == "file"
        secret_path = home.join("device.secret")
        raise Error, "设备密钥文件不存在" unless secret_path.file?
        return secret_path.read(encoding: "UTF-8").strip
      end

      stdout, _stderr, status = Open3.capture3(
        "security", "find-generic-password", "-a", device, "-s", KEYCHAIN_SERVICE, "-w"
      )
      raise Error, "Keychain 中没有这台设备的两头乌密钥" unless status.success?
      stdout.strip
    rescue Errno::ENOENT
      raise Error, "当前系统没有可用的 macOS Keychain 命令"
    end

    def store_secret(device_id, secret, store: nil)
      raise Error, "服务器返回了无效的设备密钥" unless secret.match?(/\A[A-Za-z0-9_-]{32,256}\z/)

      selected = store || ENV.fetch("WU_REMOTE_SECRET_STORE", "keychain")
      if selected == "file"
        Atomic.write(home.join("device.secret"), secret + "\n", mode: 0o600)
        return "file"
      end
      raise Error, "只支持 keychain 或 file 密钥存储" unless selected == "keychain"

      _stdout, _stderr, status = Open3.capture3(
        "security", "add-generic-password", "-U", "-a", device_id, "-s", KEYCHAIN_SERVICE, "-w", secret
      )
      raise Error, "无法把设备密钥写入 macOS Keychain" unless status.success?
      "keychain"
    rescue Errno::ENOENT
      raise Error, "当前系统没有可用的 macOS Keychain 命令；测试环境可显式选择 file"
    end

    def paths
      {
        "components" => home.join("components"),
        "results" => home.join("results"),
        "artifacts" => home.join("artifacts"),
        "tmp" => home.join("tmp")
      }
    end

    private

    def default_state
      {
        "schema_version" => 1,
        "module_policies" => {},
        "installed_modules" => {},
        "event_cursors" => {},
        "active_projects" => {},
        "companion_notified" => {}
      }
    end

    def validate_endpoint!(text)
      uri = URI(text)
      allowed_http = ENV["WU_REMOTE_ALLOW_HTTP"] == "1" && %w[127.0.0.1 localhost ::1].include?(uri.host)
      raise Error, "控制面必须使用 HTTPS" unless uri.scheme == "https" || (uri.scheme == "http" && allowed_http)
      raise Error, "控制面地址不能包含用户信息" if uri.userinfo
      raise Error, "控制面地址缺少主机" unless uri.host
      true
    rescue URI::InvalidURIError
      raise Error, "控制面地址无效"
    end
  end

  class HTTPClient
    def initialize(config)
      @config_store = config
      @config = config.load
      @base = URI(@config.fetch("endpoint"))
    end

    def self.enroll(endpoint:, token:, device_name:, secret_store: nil, config: Config.new)
      uri = URI(endpoint)
      request_uri = join_path(uri.path, "enroll")
      target = uri.dup
      target.path = request_uri
      target.query = nil
      body = JSON.generate("device_name" => device_name, "role" => "owner-air")
      request = Net::HTTP::Post.new(target.request_uri)
      request["Content-Type"] = "application/json"
      request["Authorization"] = "Enrollment #{token}"
      request.body = body
      response = perform(target, request)
      value = parse_response(response)
      device_id = value.fetch("device_id")
      secret = value.fetch("device_secret")
      store = config.store_secret(device_id, secret, store: secret_store)
      config.save(
        "endpoint" => endpoint,
        "device_id" => device_id,
        "device_name" => device_name,
        "secret_store" => store,
        "owner" => "example-owner"
      )
      value.reject { |key, _| key == "device_secret" }.merge("secret_store" => store)
    rescue KeyError => error
      raise Error, "配对响应不完整：#{error.message}"
    end

    def get(path)
      request(:get, path)
    end

    def post(path, value)
      request(:post, path, JSON.generate(value), "application/json")
    end

    def get_bytes(path)
      request(:get, path, nil, nil, parse_json: false)
    end

    private

    def request(method, path, body = nil, content_type = nil, parse_json: true)
      uri = @base.dup
      relative = URI(path.to_s)
      uri.path = self.class.join_path(@base.path, relative.path)
      uri.query = relative.query
      klass = method == :get ? Net::HTTP::Get : Net::HTTP::Post
      request = klass.new(uri.request_uri)
      request.body = body if body
      request["Content-Type"] = content_type if content_type
      sign!(request, uri.request_uri, body.to_s)
      response = self.class.perform(uri, request)
      unless parse_json
        return response.body.to_s if response.code.to_i.between?(200, 299)
        self.class.parse_response(response)
      end

      self.class.parse_response(response)
    end

    def sign!(request, path, body)
      device = @config.fetch("device_id")
      timestamp = Time.now.to_i.to_s
      nonce = SecureRandom.hex(16)
      body_hash = Digest::SHA256.hexdigest(body)
      canonical = [request.method.upcase, path, timestamp, nonce, body_hash].join("\n")
      @device_secret ||= @config_store.secret(device)
      signature = OpenSSL::HMAC.hexdigest("SHA256", @device_secret, canonical)
      request["X-Wu-Device"] = device
      request["X-Wu-Time"] = timestamp
      request["X-Wu-Nonce"] = nonce
      request["X-Wu-Signature"] = signature
      request["User-Agent"] = "two-head-wu-remote/#{VERSION}"
    end

    class << self
      def join_path(base, suffix)
        left = base.to_s.sub(%r{/+\z}, "")
        right = suffix.to_s.sub(%r{\A/+}, "")
        "#{left}/#{right}".sub(%r{\A/+}, "/")
      end

      def perform(uri, request)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = 10
        http.read_timeout = 60
        http.start { |session| session.request(request) }
      rescue OpenSSL::SSL::SSLError, Net::OpenTimeout, Net::ReadTimeout, SocketError, SystemCallError => error
        raise Error, "无法连接两头乌控制面：#{error.class}"
      end

      def parse_response(response)
        value = JSON.parse(response.body.to_s.empty? ? "{}" : response.body)
        return value if response.code.to_i.between?(200, 299)

        raise Error, value["error"] || "控制面返回 HTTP #{response.code}"
      rescue JSON::ParserError
        raise Error, "控制面返回了无效响应（HTTP #{response.code}）"
      end
    end
  end

  module Archive
    module_function

    DEFAULT_EXCLUDED_NAMES = %w[.git .env .env.local auth.json node_modules __pycache__ .venv vendor target].freeze
    DEFAULT_EXCLUDED_SUFFIXES = %w[.key .pem .p12 .pfx].freeze

    def pack_directory(source, output, maximum_bytes: 52_428_800, excluded_names: DEFAULT_EXCLUDED_NAMES,
                       excluded_suffixes: DEFAULT_EXCLUDED_SUFFIXES)
      root = Pathname.new(source).expand_path.cleanpath
      raise Error, "项目目录不存在" unless root.directory?

      total = 0
      FileUtils.mkdir_p(Pathname.new(output).dirname.to_s)
      Zlib::GzipWriter.open(output.to_s) do |gzip|
        Gem::Package::TarWriter.new(gzip) do |tar|
          Find.find(root.to_s) do |raw|
            path = Pathname.new(raw)
            next if path == root
            relative = path.relative_path_from(root).to_s
            basename = path.basename.to_s
            if excluded_names.include?(basename) || excluded_suffixes.any? { |suffix| basename.end_with?(suffix) } || credential_shaped?(basename)
              Find.prune if path.directory?
              next
            end
            next if path.symlink?
            stat = path.stat
            if stat.directory?
              tar.mkdir(relative, stat.mode & 0o755)
            elsif stat.file?
              total += stat.size
              raise Error, "项目胶囊超过允许大小" if total > maximum_bytes
              tar.add_file_simple(relative, stat.mode & 0o755, stat.size) do |io|
                File.open(path.to_s, "rb") { |file| IO.copy_stream(file, io) }
              end
            end
          end
        end
      end
      { "sha256" => Digest::SHA256.file(output.to_s).hexdigest, "size" => File.size(output.to_s) }
    end

    def unpack(archive, destination, maximum_bytes: 52_428_800)
      root = Pathname.new(destination).expand_path.cleanpath
      FileUtils.mkdir_p(root.to_s, mode: 0o700)
      total = 0
      Zlib::GzipReader.open(archive.to_s) do |gzip|
        Gem::Package::TarReader.new(gzip) do |tar|
          tar.each do |entry|
            name = entry.full_name.to_s
            raise Error, "归档包含不安全路径" if name.empty? || name.start_with?("/")
            relative = Pathname.new(name).cleanpath
            raise Error, "归档路径越界" if relative.each_filename.any? { |part| part == ".." }
            target = root.join(relative).cleanpath
            prefix = root.to_s + File::SEPARATOR
            raise Error, "归档路径越界" unless target.to_s.start_with?(prefix)
            if entry.directory?
              FileUtils.mkdir_p(target.to_s, mode: 0o755)
            elsif entry.file?
              total += entry.header.size
              raise Error, "归档解压后超过允许大小" if total > maximum_bytes
              FileUtils.mkdir_p(target.dirname.to_s, mode: 0o755)
              File.open(target.to_s, "wb", entry.header.mode & 0o755) { |file| IO.copy_stream(entry, file) }
            else
              raise Error, "归档包含不支持的链接或设备条目"
            end
          end
        end
      end
      total
    rescue Zlib::GzipFile::Error, Gem::Package::TarInvalidError => error
      raise Error, "归档无效：#{error.class}"
    end

    def credential_shaped?(basename)
      basename.match?(/\A(?:credentials?|secrets?|tokens?)(?:\.|\z)/i) || basename.match?(/auth.*\.json\z/i)
    end
  end

  module InvocationEnvelope
    module_function

    def success(request_id:, capability_id:, job_id:, output:, mini_status: "online", observed_at: Time.now.utc.iso8601)
      {
        "schema_version" => 1,
        "request_id" => request_id,
        "job_id" => job_id,
        "capability_id" => capability_id,
        "requested_executor" => "mac-mini",
        "actual_executor" => "mac-mini",
        "remote_call_succeeded" => true,
        "mini_status" => mini_status,
        "fallback_reason" => nil,
        "state" => "succeeded",
        "observed_at" => observed_at,
        "output" => output
      }
    end

    def queued(request_id:, capability_id:, job_id:, mini_status:, reason:, observed_at: Time.now.utc.iso8601)
      {
        "schema_version" => 1,
        "request_id" => request_id,
        "job_id" => job_id,
        "capability_id" => capability_id,
        "requested_executor" => "mac-mini",
        "actual_executor" => "none",
        "remote_call_succeeded" => false,
        "mini_status" => mini_status,
        "fallback_reason" => reason,
        "state" => "queued",
        "observed_at" => observed_at,
        "error" => "本轮未能成功调用两头乌 Mini；任务已进入 Mini 等待队列。"
      }
    end

    def failure(request_id:, capability_id:, mini_status:, reason:, observed_at: Time.now.utc.iso8601)
      {
        "schema_version" => 1,
        "request_id" => request_id,
        "capability_id" => capability_id,
        "requested_executor" => "mac-mini",
        "actual_executor" => "none",
        "remote_call_succeeded" => false,
        "mini_status" => mini_status,
        "fallback_reason" => reason,
        "state" => "failed",
        "observed_at" => observed_at,
        "error" => "本轮未能成功调用两头乌 Mini：#{reason}"
      }
    end
  end

  module ProjectSnapshot
    MAX_DELTA_BYTES = 8 * 1024 * 1024
    MAX_DELTA_ENTRIES = 256
    module_function

    def manifest(source)
      root = Pathname.new(source).expand_path.cleanpath
      raise Error, "项目目录不存在" unless root.directory?

      result = {}
      Find.find(root.to_s) do |raw|
        path = Pathname.new(raw)
        next if path == root
        basename = path.basename.to_s
        if excluded?(basename)
          Find.prune if path.directory?
          next
        end
        next if path.symlink? || !path.file?
        relative = path.relative_path_from(root).to_s
        result[relative] = Digest::SHA256.file(path.to_s).hexdigest
      end
      result.sort.to_h
    end

    def delta(source, previous_manifest)
      root = Pathname.new(source).expand_path.cleanpath
      before = previous_manifest.is_a?(Hash) ? previous_manifest : {}
      current = manifest(root)
      entries = []
      total = 0
      current.each do |relative, digest|
        next if before[relative] == digest
        path = safe_path(root, relative)
        bytes = path.binread
        total += bytes.bytesize
        raise Error, "项目增量超过允许大小" if total > MAX_DELTA_BYTES
        entries << {
          "path" => relative,
          "operation" => "upsert",
          "base_sha256" => before[relative],
          "sha256" => digest,
          "content_base64" => Base64.strict_encode64(bytes)
        }
      end
      (before.keys - current.keys).sort.each do |relative|
        entries << { "path" => relative, "operation" => "delete", "base_sha256" => before[relative] }
      end
      raise Error, "项目增量文件数超过允许上限" if entries.length > MAX_DELTA_ENTRIES
      [entries, current]
    end

    def safe_path(root, relative)
      text = relative.to_s
      candidate = Pathname.new(text)
      raise Error, "项目增量路径无效" if text.empty? || candidate.absolute? || candidate.each_filename.any? { |part| part == ".." }
      target = root.join(candidate).cleanpath
      prefix = root.to_s + File::SEPARATOR
      raise Error, "项目增量路径越界" unless target.to_s.start_with?(prefix)
      target
    end

    def excluded?(basename)
      Archive::DEFAULT_EXCLUDED_NAMES.include?(basename) ||
        Archive::DEFAULT_EXCLUDED_SUFFIXES.any? { |suffix| basename.end_with?(suffix) } ||
        Archive.credential_shaped?(basename)
    end
  end
end
