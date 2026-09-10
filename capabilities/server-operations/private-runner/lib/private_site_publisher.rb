#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "net/http"
require "openssl"
require "open3"
require "pathname"
require "rubygems/package"
require "shellwords"
require "time"
require "timeout"
require "uri"
require "yaml"

class PrivateSitePublisherError < StandardError; end

# This is service-side code.  It must be copied to, and run from, a protected
# system-service installation before it can hold a deployment identity.  The
# public Skill and its client never load this file or private configuration.
class PrivateSitePublisherService
  SITE_IDS = %w[private-site public-site].freeze
  RELEASE_ID = /\Apublish-[0-9]{8}T[0-9]{6}Z-[a-z0-9-]+-[0-9a-f]{8}\z/.freeze
  REQUEST_TTL_SECONDS = 24 * 60 * 60
  DEFAULT_ATTEMPTS = 4
  DEFAULT_RETRY_SECONDS = 5
  MAX_ARCHIVE_BYTES = 100 * 1024 * 1024
  MAX_ARCHIVE_FILES = 10_000
  MAX_RETAINED_RELEASE_RECORDS = 2_048
  RELEASE_RECORD_RETENTION_SECONDS = 90 * 24 * 60 * 60
  FORBIDDEN_FILE_EXTENSIONS = %w[.pem .key .p12 .pfx .kdbx .sqlite .sqlite3 .db .sql .dump .bak].freeze
  FORBIDDEN_DYNAMIC_EXTENSIONS = %w[.php .phtml .cgi .fcgi .pl .py .rb .sh .bash .zsh .ps1].freeze
  FORBIDDEN_FILE_NAMES = %w[id_rsa id_dsa id_ecdsa id_ed25519 authorized_keys credentials secrets .htaccess nginx.conf caddyfile].freeze

  # +root+ is deliberately not used as a source of authorization. Private
  # configuration binds each permitted project ID to its registered workspace,
  # but the privileged service never traverses that workspace: an unprivileged
  # client supplies a regular archive file descriptor over the fixed IPC socket.
  def initialize(root:, private_root:, transport: nil, verifier: nil, sleeper: nil, clock: nil)
    @root = Pathname.new(root).expand_path.cleanpath
    @private_root = Pathname.new(private_root).expand_path.cleanpath
    @config_path = @private_root.join("site-publisher.yaml")
    # Injection exists only for local tests.  The service executable exposes no
    # command line option for any of these values.
    @transport = transport
    @verifier = verifier
    @sleeper = sleeper || ->(seconds) { sleep(seconds) }
    @clock = clock || -> { Time.now.utc }
  end

  def ready?
    configuration = load_configuration!
    validate_private_transport_files! if @transport.nil?
    configuration
    true
  end

  # Fixed IPC protocol entry point.  It accepts no server, path, command,
  # configuration, credential, or source arguments.
  def handle_request(payload, artifact_io: nil)
    raise PrivateSitePublisherError, "publisher request is invalid" unless payload.is_a?(Hash)
    case payload.fetch("schema_version")
    when 1
      handle_v1_request!(payload, artifact_io)
    when 2
      handle_v2_request!(payload, artifact_io)
    else
      raise PrivateSitePublisherError, "publisher request is invalid"
    end
  rescue KeyError, TypeError
    raise PrivateSitePublisherError, "publisher request is invalid"
  end

  # A release is intentionally single-use. Its unprivileged client packages the
  # frozen copy before contacting this service; this process receives only that
  # archive descriptor and extracts it directly under its private root before
  # SSH is attempted.
  def publish(envelope, artifact_io:)
    release_id = envelope.fetch("release_id")
    validate_release_id!(release_id)
    configuration = load_configuration!
    validate_private_transport_files! if @transport.nil?
    request = parse_request!(envelope.fetch("request"), release_id)
    project_id = envelope.fetch("project_id")
    raise PrivateSitePublisherError, "publication request is not authorized" unless request.fetch("project_id") == project_id
    project = configuration.fetch("projects").fetch(project_id)
    raise PrivateSitePublisherError, "publication request is not authorized" unless Array(project.fetch("allowed_sites")).include?(request.fetch("site_id"))
    target = configuration.fetch("targets").fetch(request.fetch("site_id"))
    claim_release!(release_id, request)

    begin
      update_state!(release_id, request, "running")
      private_snapshot = extract_archive_to_private_staging!(release_id, artifact_io, request)
      artifact = inspect_artifact!(private_snapshot, expected_request: request)
      unless artifact.fetch("artifact_digest") == request.fetch("artifact_digest") &&
             artifact.fetch("source_artifact_digest") == request.fetch("source_artifact_digest") &&
             artifact.fetch("file_count") == request.fetch("file_count") &&
             artifact.fetch("total_bytes") == request.fetch("total_bytes")
        raise PrivateSitePublisherError, "frozen publication snapshot no longer matches its request"
      end

      publish_with_retries!(release_id, request, target, private_snapshot, artifact)
    rescue PrivateSitePublisherError => error
      mark_failed!(release_id, request, error)
      raise
    rescue StandardError
      error = PrivateSitePublisherError.new("publication did not complete")
      mark_failed!(release_id, request, error)
      raise error
    ensure
      # A completed synchronous release has no local retry queue. Keeping its
      # full static copy would let Socket-group callers exhaust the protected
      # disk, while the small redacted state/audit record remains available for
      # `status`. The fixed release ID makes this deletion narrowly scoped.
      remove_private_staging!(release_id)
    end
  end

  def status(release_id)
    validate_release_id!(release_id)
    state = read_state!(release_id)
    redact_state(state)
  end

  private

  def active_transport
    @transport ||= RsyncSshTransport.new
  end

  def active_verifier
    @verifier ||= HttpsReleaseMarkerVerifier.new
  end

  def handle_v1_request!(payload, artifact_io)
    raise PrivateSitePublisherError, "publisher request is invalid" unless artifact_io.nil?

    case payload.fetch("action")
    when "ready"
      validate_request_shape!(payload, %w[schema_version action])
      ready?
      { "schema_version" => 1, "result" => "ready" }
    when "status"
      validate_request_shape!(payload, %w[schema_version action release_id])
      status(payload.fetch("release_id"))
    else
      raise PrivateSitePublisherError, "publisher request is invalid"
    end
  end

  def handle_v2_request!(payload, artifact_io)
    validate_request_shape!(payload, %w[schema_version action release_id project_id request])
    raise PrivateSitePublisherError, "publisher request is invalid" unless payload.fetch("action") == "publish"
    raise PrivateSitePublisherError, "publisher request is invalid" if artifact_io.nil?

    publish(payload, artifact_io: artifact_io)
  end

  def validate_request_shape!(payload, allowed_keys)
    raise PrivateSitePublisherError, "publisher request is invalid" unless payload.keys.sort == allowed_keys.sort
  end

  def validate_release_id!(release_id)
    raise PrivateSitePublisherError, "publication request is invalid" unless RELEASE_ID.match?(release_id.to_s)
  end

  def load_configuration!
    ensure_private_root_chain!
    ensure_secure_directory!(@private_root, "private publisher state")
    ensure_secure_regular_file!(@config_path, "private publisher configuration")
    configuration = YAML.safe_load(@config_path.read(encoding: "UTF-8"), permitted_classes: [], aliases: false)
    raise PrivateSitePublisherError, "private publisher configuration is invalid" unless configuration.is_a?(Hash)
    raise PrivateSitePublisherError, "private publisher configuration is invalid" unless configuration.fetch("schema_version") == 3

    allowed = %w[schema_version targets projects]
    raise PrivateSitePublisherError, "private publisher configuration is invalid" unless configuration.keys.sort == allowed.sort
    targets = configuration.fetch("targets")
    projects = configuration.fetch("projects")
    raise PrivateSitePublisherError, "private publisher configuration is invalid" unless targets.is_a?(Hash) && targets.keys.sort == SITE_IDS
    raise PrivateSitePublisherError, "private publisher configuration is invalid" unless projects.is_a?(Hash) && !projects.empty?
    targets.each { |site_id, target| validate_target!(site_id, target) }
    projects.each { |project_id, project| validate_project!(project_id, project) }
    configuration
  rescue KeyError, Psych::Exception, Errno::EACCES
    raise PrivateSitePublisherError, "private publisher configuration is unavailable or invalid"
  end

  def validate_target!(site_id, target)
    allowed = %w[transport ssh_target remote_root delete_policy verification verification_url]
    required = allowed
    raise PrivateSitePublisherError, "private publisher configuration is invalid" unless target.is_a?(Hash) && (target.keys - allowed).empty?
    raise PrivateSitePublisherError, "private publisher configuration is invalid" unless required.all? { |key| target.key?(key) }
    raise PrivateSitePublisherError, "private publisher configuration is invalid" unless SITE_IDS.include?(site_id)
    raise PrivateSitePublisherError, "private publisher configuration is invalid" unless target.fetch("transport") == "rsync_ssh"
    raise PrivateSitePublisherError, "private publisher configuration is invalid" unless target.fetch("delete_policy") == "mirror"
    raise PrivateSitePublisherError, "private publisher configuration is invalid" unless target.fetch("verification") == "https-release-marker"
    raise PrivateSitePublisherError, "private publisher configuration is invalid" unless safe_ssh_target?(target.fetch("ssh_target"))
    raise PrivateSitePublisherError, "private publisher configuration is invalid" unless safe_remote_root?(target.fetch("remote_root"))
    raise PrivateSitePublisherError, "private publisher configuration is invalid" unless safe_verification_url?(target.fetch("verification_url"))
  end

  def validate_project!(project_id, project)
    allowed = %w[workspace allowed_sites]
    raise PrivateSitePublisherError, "private publisher configuration is invalid" unless safe_project_id?(project_id)
    raise PrivateSitePublisherError, "private publisher configuration is invalid" unless project.is_a?(Hash) && (project.keys - allowed).empty?
    raise PrivateSitePublisherError, "private publisher configuration is invalid" unless allowed.all? { |key| project.key?(key) }
    raise PrivateSitePublisherError, "private publisher configuration is invalid" unless safe_workspace?(project.fetch("workspace"))
    sites = Array(project.fetch("allowed_sites"))
    raise PrivateSitePublisherError, "private publisher configuration is invalid" if sites.empty? || (sites - SITE_IDS).any?
  end

  def safe_project_id?(value)
    value.is_a?(String) && value.match?(/\A[a-z0-9][a-z0-9-]{0,62}\z/)
  end

  def safe_workspace?(value)
    value.is_a?(String) && value.start_with?(File::SEPARATOR) && !value.include?("\0")
  end

  def safe_ssh_target?(value)
    return false unless value.is_a?(String) && value.bytesize.between?(1, 253)

    value.match?(/\A(?:[A-Za-z0-9][A-Za-z0-9_.-]*@)?[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\z/)
  end

  def safe_remote_root?(value)
    return false unless value.is_a?(String) && value.start_with?(File::SEPARATOR) && !value.include?("\0")

    parts = value.split(File::SEPARATOR).reject(&:empty?)
    !parts.empty? && parts.all? { |part| part != "." && part != ".." && part.match?(/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/) }
  end

  def safe_verification_url?(value)
    uri = URI.parse(value)
    return false unless uri.is_a?(URI::HTTPS) && uri.port == 443 && uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?
    return false unless uri.host && uri.host.match?(/\A(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}\z/)

    path_parts = uri.path.split(File::SEPARATOR).reject(&:empty?)
    path_parts.none? { |part| part == "." || part == ".." }
  rescue URI::InvalidURIError
    false
  end

  def validate_private_transport_files!
    %w[ssh_config id_ed25519 known_hosts].each do |name|
      ensure_secure_regular_file!(@private_root.join(name), "private publisher transport")
    end
    raise PrivateSitePublisherError, "private publisher transport is unavailable" unless RsyncSshTransport.available?
  end

  def parse_request!(request, release_id)
    required = %w[schema_version publication_id created_at project_id site_id preflight_id artifact_digest source_artifact_digest file_count total_bytes execution]
    raise PrivateSitePublisherError, "publication request is invalid" unless request.is_a?(Hash) && request.keys.sort == required.sort
    raise PrivateSitePublisherError, "publication request is invalid" unless request.fetch("schema_version") == 2
    raise PrivateSitePublisherError, "publication request is invalid" unless request.fetch("publication_id") == release_id
    raise PrivateSitePublisherError, "publication request is invalid" unless safe_project_id?(request.fetch("project_id")) && SITE_IDS.include?(request.fetch("site_id"))
    %w[artifact_digest source_artifact_digest].each do |key|
      raise PrivateSitePublisherError, "publication request is invalid" unless request.fetch(key).is_a?(String) && request.fetch(key).match?(/\A[0-9a-f]{64}\z/)
    end
    raise PrivateSitePublisherError, "publication request is invalid" unless request.fetch("preflight_id").is_a?(String) && request.fetch("preflight_id").bytesize.between?(1, 160)
    raise PrivateSitePublisherError, "publication request is invalid" unless request.fetch("file_count").is_a?(Integer) && request.fetch("file_count").between?(1, MAX_ARCHIVE_FILES)
    raise PrivateSitePublisherError, "publication request is invalid" unless request.fetch("total_bytes").is_a?(Integer) && request.fetch("total_bytes").between?(1, MAX_ARCHIVE_BYTES)
    raise PrivateSitePublisherError, "publication request is invalid" unless request.fetch("execution") == "codex-driven-protected-executor"
    created_at = Time.iso8601(request.fetch("created_at").to_s)
    age = @clock.call - created_at
    raise PrivateSitePublisherError, "publication request has expired" if age > REQUEST_TTL_SECONDS || age < -300

    request
  rescue TypeError, ArgumentError
    raise PrivateSitePublisherError, "publication request is invalid"
  end

  def claim_release!(release_id, request)
    directory = state_directory!
    prune_expired_release_records!(directory)
    retained_records = Dir.children(directory).count { |name| name.end_with?(".json") }
    if retained_records >= MAX_RETAINED_RELEASE_RECORDS
      raise PrivateSitePublisherError, "private publication state capacity is unavailable"
    end
    path = directory.join("#{release_id}.json")
    state = state_payload(request, "queued", attempts: 0)
    File.open(path.to_s, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(JSON.generate(state) + "\n") }
  rescue Errno::EEXIST
    raise PrivateSitePublisherError, "publication has already been accepted"
  rescue SystemCallError
    raise PrivateSitePublisherError, "private publication state is unavailable"
  end

  # Terminal records are useful for status/audit but must not be an unbounded
  # storage sink for a Socket-group caller. Only service-owned, completed
  # records older than the documented retention period are removed.
  def prune_expired_release_records!(directory)
    cutoff = @clock.call - RELEASE_RECORD_RETENTION_SECONDS
    Dir.children(directory).grep(/\.json\z/).each do |name|
      release_id = name.delete_suffix(".json")
      next unless RELEASE_ID.match?(release_id)

      path = directory.join(name)
      ensure_secure_regular_file!(path, "private publication state")
      record = JSON.parse(path.read(encoding: "UTF-8"))
      next unless %w[verified failed].include?(record["state"])
      updated_at = Time.iso8601(record.fetch("updated_at"))
      next unless updated_at < cutoff

      File.delete(path.to_s)
      audit_path = @private_root.join("audit", name)
      remove_expired_audit_record!(audit_path)
    end
  rescue JSON::ParserError, KeyError, TypeError, ArgumentError, SystemCallError
    raise PrivateSitePublisherError, "private publication state is unavailable"
  end

  def remove_expired_audit_record!(path)
    return unless path.exist? || path.symlink?

    ensure_secure_regular_file!(path, "private publication audit")
    File.delete(path.to_s)
  end

  # Import only a regular archive FD supplied by the unprivileged local client.
  # Do not replace this with a path in a project workspace: doing so would make a
  # privileged service follow a potentially raced, agent-writable directory tree.
  def extract_archive_to_private_staging!(release_id, artifact_io, request)
    validate_archive_io!(artifact_io)
    destination_root = staging_directory!.join(release_id)
    destination = destination_root.join("artifact")
    FileUtils.mkdir_p(destination_root.to_s, mode: 0o700)
    File.chmod(0o700, destination_root.to_s)
    FileUtils.mkdir_p(destination.to_s, mode: 0o755)
    File.chmod(0o755, destination.to_s)
    artifact_io.rewind
    entries = 0
    written_bytes = 0
    Gem::Package::TarReader.new(artifact_io) do |archive|
      archive.each do |entry|
        entries += 1
        raise PrivateSitePublisherError, "publication archive is invalid" if entries > MAX_ARCHIVE_FILES

        relative = archive_relative_path!(entry.full_name)
        raise PrivateSitePublisherError, "publication archive contains a prohibited file" if forbidden_artifact_path?(relative)
        output_path = destination.join(*relative.split(File::SEPARATOR))
        if entry.directory?
          FileUtils.mkdir_p(output_path.to_s, mode: 0o755)
          File.chmod(0o755, output_path.to_s)
        elsif entry.file?
          FileUtils.mkdir_p(output_path.dirname.to_s, mode: 0o755)
          File.chmod(0o755, output_path.dirname.to_s)
          write_archive_file!(entry, output_path, written_bytes)
          written_bytes += entry.header.size
          raise PrivateSitePublisherError, "publication archive is too large" if written_bytes > MAX_ARCHIVE_BYTES
        else
          raise PrivateSitePublisherError, "publication archive contains an unsupported entry"
        end
      end
    end
    raise PrivateSitePublisherError, "publication archive is empty" if entries.zero?
    destination
  rescue Gem::Package::TarInvalidError, EOFError, IOError, SystemCallError
    raise PrivateSitePublisherError, "publication archive is invalid"
  end

  def validate_archive_io!(artifact_io)
    raise PrivateSitePublisherError, "publication archive is invalid" unless artifact_io.respond_to?(:stat) && artifact_io.respond_to?(:rewind)
    stat = artifact_io.stat
    raise PrivateSitePublisherError, "publication archive is invalid" unless stat.file? && stat.size.positive? && stat.size <= MAX_ARCHIVE_BYTES
  rescue SystemCallError
    raise PrivateSitePublisherError, "publication archive is invalid"
  end

  def archive_relative_path!(name)
    raise PrivateSitePublisherError, "publication archive is invalid" unless name.is_a?(String) && name.bytesize.between?(1, 1024)
    parts = name.split(File::SEPARATOR)
    unsafe = name.start_with?(File::SEPARATOR) || name.include?("\0") || parts.empty? || parts.any? { |part| part.empty? || part == "." || part == ".." || part.include?("\\") }
    raise PrivateSitePublisherError, "publication archive is invalid" if unsafe

    name
  end

  def write_archive_file!(entry, output_path, already_written)
    size = entry.header.size
    raise PrivateSitePublisherError, "publication archive is too large" unless size.is_a?(Integer) && size >= 0 && already_written + size <= MAX_ARCHIVE_BYTES
    File.open(output_path.to_s, File::WRONLY | File::CREAT | File::EXCL, 0o644) do |output|
      copied = IO.copy_stream(entry, output, size)
      raise PrivateSitePublisherError, "publication archive is invalid" unless copied == size
    end
    File.chmod(0o644, output_path.to_s)
  end

  def inspect_artifact!(root, expected_request:)
    full = scan_artifact!(root, skip_release_marker: false)
    source = scan_artifact!(root, skip_release_marker: true)
    marker_path = root.join(".two-head-wu-release.json")
    ensure_regular_file!(marker_path, "release marker")
    marker = JSON.parse(marker_path.read(encoding: "UTF-8"))
    expected = {
      "schema_version" => 2,
      "publication_id" => expected_request.fetch("publication_id"),
      "site_id" => expected_request.fetch("site_id"),
      "source_artifact_digest" => expected_request.fetch("source_artifact_digest")
    }
    raise PrivateSitePublisherError, "frozen publication snapshot has an invalid release marker" unless expected.all? { |key, value| marker[key] == value }

    full.merge("source_artifact_digest" => source.fetch("artifact_digest"))
  rescue JSON::ParserError, TypeError
    raise PrivateSitePublisherError, "frozen publication snapshot has an invalid release marker"
  end

  def scan_artifact!(root, skip_release_marker:)
    digest = Digest::SHA256.new
    report = { "file_count" => 0, "total_bytes" => 0 }
    scan_directory!(root, root, digest, report, skip_release_marker: skip_release_marker)
    raise PrivateSitePublisherError, "frozen publication snapshot is empty" if report.fetch("file_count").zero?
    report.merge("artifact_digest" => digest.hexdigest)
  end

  def scan_directory!(root, directory, digest, report, skip_release_marker:)
    Dir.children(directory).sort.each do |name|
      path = directory.join(name)
      relative = path.relative_path_from(root).to_s
      next if skip_release_marker && relative == ".two-head-wu-release.json"

      stat = path.lstat
      raise PrivateSitePublisherError, "frozen publication snapshot contains a symbolic link" if stat.symlink?
      raise PrivateSitePublisherError, "frozen publication snapshot contains a prohibited file" if forbidden_artifact_path?(relative)
      if stat.directory?
        digest.update("D\0#{relative}\0")
        scan_directory!(root, path, digest, report, skip_release_marker: skip_release_marker)
      elsif stat.file?
        file_digest = Digest::SHA256.file(path.to_s).hexdigest
        digest.update("F\0#{relative}\0#{stat.size}\0#{file_digest}\0")
        report["file_count"] += 1
        report["total_bytes"] += stat.size
      else
        raise PrivateSitePublisherError, "frozen publication snapshot contains an unsupported entry"
      end
    end
  rescue Errno::ENOENT, Errno::EACCES
    raise PrivateSitePublisherError, "frozen publication snapshot is unavailable"
  end

  def forbidden_artifact_path?(relative)
    components = relative.split(File::SEPARATOR)
    return true if components.any? { |component| %w[.git .hg .svn].include?(component) }

    name = components.last.downcase
    return true if name.start_with?(".env")
    return true if FORBIDDEN_FILE_NAMES.include?(name)
    extension = File.extname(name)
    FORBIDDEN_FILE_EXTENSIONS.include?(extension) || FORBIDDEN_DYNAMIC_EXTENSIONS.include?(extension)
  end

  def publish_with_retries!(release_id, request, target, snapshot, artifact)
    attempts = 0
    last_error = nil
    while attempts < DEFAULT_ATTEMPTS
      attempts += 1
      update_state!(release_id, request, "running", attempts: attempts)
      begin
        active_transport.publish(snapshot: snapshot, target: target, private_root: @private_root)
        active_verifier.verify(
          verification_url: target.fetch("verification_url"),
          publication_id: request.fetch("publication_id"),
          site_id: request.fetch("site_id"),
          artifact_digest: artifact.fetch("artifact_digest"),
          source_artifact_digest: artifact.fetch("source_artifact_digest")
        )
        result = state_payload(request, "verified", attempts: attempts).merge(
          "artifact_digest" => artifact.fetch("artifact_digest"),
          "source_artifact_digest" => artifact.fetch("source_artifact_digest"),
          "verified_at" => @clock.call.iso8601,
          "result" => "published"
        )
        persist_verified_result!(release_id, result)
        return redact_state(result)
      rescue PrivateSitePublisherError => error
        last_error = error
        update_state!(release_id, request, "retry_wait", attempts: attempts) if attempts < DEFAULT_ATTEMPTS
        @sleeper.call(DEFAULT_RETRY_SECONDS) if attempts < DEFAULT_ATTEMPTS
      end
    end
    raise PrivateSitePublisherError, "automatic publication failed after #{DEFAULT_ATTEMPTS} attempts: #{safe_failure_message(last_error)}"
  end

  def mark_failed!(release_id, request, error)
    state = state_payload(request, "failed").merge(
      "failed_at" => @clock.call.iso8601,
      "result" => "failed",
      "failure" => safe_failure_message(error)
    )
    write_state!(release_id, state)
  rescue PrivateSitePublisherError
    # Preserve the original, generic publication error.
  end

  # Once transport plus HTTPS verification succeeds, the release is externally
  # complete.  A later local audit-storage failure must not cause another upload
  # or turn a verified publication into a false failure.
  def persist_verified_result!(release_id, result)
    write_state!(release_id, result)
    write_audit!(result)
  rescue PrivateSitePublisherError
    nil
  end

  def state_payload(request, state, attempts: nil)
    payload = {
      "schema_version" => 1,
      "publication_id" => request.fetch("publication_id"),
      "site_id" => request.fetch("site_id"),
      "state" => state,
      "updated_at" => @clock.call.iso8601
    }
    payload["attempts"] = attempts unless attempts.nil?
    payload
  end

  def update_state!(release_id, request, state, attempts: nil)
    write_state!(release_id, state_payload(request, state, attempts: attempts))
  end

  def write_state!(release_id, payload)
    path = state_directory!.join("#{release_id}.json")
    temporary = path.sub_ext(".tmp-#{Process.pid}-#{rand(1_000_000)}")
    File.open(temporary.to_s, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(JSON.generate(payload) + "\n") }
    File.rename(temporary.to_s, path.to_s)
    File.chmod(0o600, path.to_s)
  rescue SystemCallError
    raise PrivateSitePublisherError, "private publication state is unavailable"
  ensure
    begin
      File.delete(temporary.to_s) if defined?(temporary) && temporary.exist?
    rescue SystemCallError
      nil
    end
  end

  def read_state!(release_id)
    path = state_directory!.join("#{release_id}.json")
    ensure_secure_regular_file!(path, "private publication state")
    JSON.parse(path.read(encoding: "UTF-8"))
  rescue JSON::ParserError, TypeError
    raise PrivateSitePublisherError, "private publication state is unavailable"
  end

  def redact_state(state)
    allowed = %w[schema_version publication_id site_id state attempts artifact_digest source_artifact_digest verified_at failed_at result failure updated_at]
    state.slice(*allowed)
  end

  def state_directory!
    directory = @private_root.join("state")
    FileUtils.mkdir_p(directory.to_s, mode: 0o700)
    File.chmod(0o700, directory.to_s)
    ensure_secure_directory!(directory, "private publication state")
    directory
  end

  def write_audit!(result)
    directory = @private_root.join("audit")
    FileUtils.mkdir_p(directory.to_s, mode: 0o700)
    File.chmod(0o700, directory.to_s)
    ensure_secure_directory!(directory, "private publication audit")
    path = directory.join("#{result.fetch('publication_id')}.json")
    File.open(path.to_s, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
      file.write(JSON.generate(redact_state(result)) + "\n")
    end
  rescue Errno::EEXIST
    raise PrivateSitePublisherError, "private publication state is unavailable"
  rescue SystemCallError
    raise PrivateSitePublisherError, "private publication state is unavailable"
  end

  def staging_directory!
    directory = @private_root.join("staging")
    FileUtils.mkdir_p(directory.to_s, mode: 0o700)
    File.chmod(0o700, directory.to_s)
    ensure_secure_directory!(directory, "private publication staging")
    directory
  end

  def remove_private_staging!(release_id)
    validate_release_id!(release_id)
    path = staging_directory!.join(release_id)
    return unless path.exist? || path.symlink?

    stat = path.lstat
    safe = !stat.symlink? && stat.directory? && stat.uid == Process.euid && (stat.mode & 0o077).zero?
    raise PrivateSitePublisherError, "private publication staging is unavailable" unless safe
    FileUtils.remove_entry_secure(path.to_s)
  rescue PrivateSitePublisherError, SystemCallError
    # Publication result is already decided. Never retry a verified remote
    # upload merely because local cleanup was unavailable.
    nil
  end

  def ensure_regular_file!(path, description)
    stat = path.lstat
    raise PrivateSitePublisherError, "#{description} is unavailable" if stat.symlink? || !stat.file?
  rescue Errno::ENOENT, Errno::EACCES
    raise PrivateSitePublisherError, "#{description} is unavailable"
  end

  def ensure_secure_regular_file!(path, description)
    stat = path.lstat
    unsafe = stat.symlink? || !stat.file? || (stat.mode & 0o077).positive? || stat.uid != Process.euid
    raise PrivateSitePublisherError, "#{description} is unavailable or unsafe" if unsafe
  rescue Errno::ENOENT, Errno::EACCES
    raise PrivateSitePublisherError, "#{description} is unavailable or unsafe"
  end

  def ensure_real_directory!(path, description)
    stat = path.lstat
    raise PrivateSitePublisherError, "#{description} is unavailable" if stat.symlink? || !stat.directory?
  rescue Errno::ENOENT, Errno::EACCES
    raise PrivateSitePublisherError, "#{description} is unavailable"
  end

  def ensure_secure_directory!(path, description)
    stat = path.lstat
    unsafe = stat.symlink? || !stat.directory? || (stat.mode & 0o077).positive? || stat.uid != Process.euid
    raise PrivateSitePublisherError, "#{description} is unavailable or unsafe" if unsafe
  rescue Errno::ENOENT, Errno::EACCES
    raise PrivateSitePublisherError, "#{description} is unavailable or unsafe"
  end

  # The service must not trust a secure-looking leaf directory through a
  # symlinked or group-writable ancestor. The production installation keeps the
  # private root service-owned and its ancestors root-owned; test installations
  # may use the current test account, but never a broadly writable ancestor.
  def ensure_private_root_chain!
    ensure_original_private_root_path!(@private_root)
    resolved_root = Pathname.new(File.realpath(@private_root.to_s)).cleanpath
    ensure_resolved_private_root_path!(resolved_root)
  rescue Errno::ENOENT, Errno::EACCES
    raise PrivateSitePublisherError, "private publisher state is unavailable or unsafe"
  end

  def ensure_original_private_root_path!(path)
    current = path
    loop do
      stat = current.lstat
      if stat.symlink?
        # A system-owned compatibility link such as macOS /var is acceptable;
        # a service/user-owned link is not. The fully resolved path is checked
        # separately below.
        raise PrivateSitePublisherError, "private publisher state is unavailable or unsafe" unless stat.uid.zero?
      else
        ensure_trusted_private_directory!(stat)
      end
      break if current.root?

      current = current.parent
    end
  end

  def ensure_resolved_private_root_path!(path)
    current = path
    loop do
      ensure_trusted_private_directory!(current.lstat)
      break if current.root?

      current = current.parent
    end
  end

  def ensure_trusted_private_directory!(stat)
      trusted_owner = stat.uid == Process.euid || stat.uid.zero?
      unsafe = stat.symlink? || !stat.directory? || !trusted_owner || (stat.mode & 0o022).positive?
      raise PrivateSitePublisherError, "private publisher state is unavailable or unsafe" if unsafe
  end

  def safe_failure_message(error)
    return "publication did not complete" unless error

    case error.message
    when /verification/ then "HTTPS verification did not pass"
    when /upload/ then "upload attempt failed"
    when /expired/ then "publication request expired"
    else "publication did not complete"
    end
  end

  class RsyncSshTransport
    SSH = "/usr/bin/ssh"
    RSYNC = "/usr/bin/rsync"
    TOTAL_UPLOAD_TIMEOUT_SECONDS = 300
    TERMINATION_GRACE_SECONDS = 5

    def self.available?
      File.executable?(SSH) && File.executable?(RSYNC)
    end

    def publish(snapshot:, target:, private_root:)
      ssh_config = private_root.join("ssh_config")
      identity = private_root.join("id_ed25519")
      known_hosts = private_root.join("known_hosts")
      rsh = [
        SSH,
        "-F", Shellwords.shellescape(ssh_config.to_s),
        "-i", Shellwords.shellescape(identity.to_s),
        "-o", "BatchMode=yes",
        "-o", "IdentitiesOnly=yes",
        "-o", "ConnectTimeout=15",
        "-o", "StrictHostKeyChecking=yes",
        "-o", "UserKnownHostsFile=#{Shellwords.shellescape(known_hosts.to_s)}"
      ].join(" ")
      destination = "#{target.fetch('ssh_target')}:#{target.fetch('remote_root')}/"
      command = [
        RSYNC,
        "--archive",
        "--delete",
        "--delay-updates",
        "--safe-links",
        "--checksum",
        "--timeout=60",
        "--chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r",
        "-e", rsh,
        "#{snapshot}/",
        destination
      ]
      status = run_bounded_command!(
        { "PATH" => "/usr/bin:/bin", "HOME" => private_root.to_s },
        command
      )
      raise PrivateSitePublisherError, "upload attempt failed" unless status.success?
    rescue Errno::ENOENT, SystemCallError, Timeout::Error
      raise PrivateSitePublisherError, "upload attempt failed"
    end

    private

    # rsync's --timeout limits inactive I/O, not the whole process lifetime.
    # Put each fixed upload attempt in its own process group and stop the group
    # on a total deadline, so the client can choose a truthful finite wait.
    def run_bounded_command!(environment, command)
      Open3.popen3(environment, *command, unsetenv_others: true, pgroup: true) do |stdin, stdout, stderr, wait_thread|
        stdin.close
        # Drain both pipes concurrently so rsync cannot block on a full stderr
        # pipe. Do not close them before their readers have reached EOF: that
        # would turn a deadline into a reader IOError and bypass retry logic.
        stdout_reader = Thread.new { safe_pipe_read(stdout) }
        stderr_reader = Thread.new { safe_pipe_read(stderr) }
        begin
          Timeout.timeout(TOTAL_UPLOAD_TIMEOUT_SECONDS) { wait_thread.value }
        rescue Timeout::Error
          terminate_process_group(wait_thread.pid, wait_thread)
          raise PrivateSitePublisherError, "upload attempt failed"
        ensure
          stdout_reader.join
          stderr_reader.join
          stdout.close unless stdout.closed?
          stderr.close unless stderr.closed?
        end
      end
    end

    def safe_pipe_read(pipe)
      pipe.read
    rescue IOError, Errno::EIO
      ""
    end

    def terminate_process_group(process_id, wait_thread)
      Process.kill("TERM", -process_id)
      return if wait_thread.join(TERMINATION_GRACE_SECONDS)

      begin
        Process.kill("KILL", -process_id)
      rescue Errno::ESRCH
        nil
      ensure
        wait_thread.join
      end
    end
  end

  class HttpsReleaseMarkerVerifier
    def verify(verification_url:, publication_id:, site_id:, artifact_digest:, source_artifact_digest:)
      uri = marker_uri!(verification_url)
      http = Net::HTTP.new(uri.host, uri.port, nil)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.open_timeout = 10
      http.read_timeout = 20
      response = http.start { |connection| connection.request(Net::HTTP::Get.new(uri.request_uri)) }
      raise PrivateSitePublisherError, "HTTPS verification did not pass" unless response.is_a?(Net::HTTPSuccess)

      marker = JSON.parse(response.body)
      matches = marker["publication_id"] == publication_id &&
                marker["site_id"] == site_id &&
                marker["source_artifact_digest"] == source_artifact_digest
      raise PrivateSitePublisherError, "HTTPS verification did not pass" unless matches
      artifact_digest
    rescue URI::InvalidURIError, SocketError, Timeout::Error, IOError, SystemCallError, OpenSSL::SSL::SSLError, JSON::ParserError
      raise PrivateSitePublisherError, "HTTPS verification did not pass"
    end

    private

    def marker_uri!(verification_url)
      uri = URI.parse(verification_url)
      raise PrivateSitePublisherError, "HTTPS verification did not pass" unless uri.is_a?(URI::HTTPS) && uri.query.nil? && uri.fragment.nil?

      base = verification_url.end_with?("/") ? verification_url : "#{verification_url}/"
      URI.join(base, ".two-head-wu-release.json")
    end
  end
end
