#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "pathname"
require "rubygems/package"
require "socket"
require "tempfile"
require "timeout"
require "yaml"

class PrivateSitePublisherClientError < StandardError; end

# Public, deliberately tiny client for the installed protected publisher.  It
# knows one fixed local socket and a release ID.  It never reads deployment
# configuration, private paths, SSH identities, or remote connection details.
#
# For publication, the unprivileged client packages the already-frozen static
# copy into a regular tar-file descriptor and passes that descriptor over the
# local socket.  The protected service therefore never walks an agent-writable
# project directory while it has access to a deployment identity.
class PrivateSitePublisherClient
  DEFAULT_SOCKET_PATH = "/Library/Application Support/TwoHeadWu/runtime/site-publisher.sock"
  RELEASE_ID = /\Apublish-[0-9]{8}T[0-9]{6}Z-[a-z0-9-]+-[0-9a-f]{8}\z/.freeze
  # Four bounded uploads (5 minutes each), HTTPS checks, and retry pauses fit
  # inside this wait. Do not set a shorter client timeout than the service's
  # synchronous bounded retry window, or a real verified publish could be
  # reported as a local client failure.
  RESPONSE_TIMEOUT_SECONDS = 30 * 60
  MAX_RESPONSE_BYTES = 16 * 1024
  SITE_IDS = %w[private-site public-site].freeze

  # +release_builder+ is test injection only.  The CLI exposes no choice of
  # archive, socket, source, project, host, or target.
  def initialize(socket_path: DEFAULT_SOCKET_PATH, release_builder: nil)
    @socket_path = socket_path
    @release_builder = release_builder || PublicReleaseArchiveBuilder.new
  end

  def ready?
    response = request_v1("ready")
    response == { "schema_version" => 1, "result" => "ready" }
  end

  def publish(release_id)
    validate_release_id!(release_id)
    release = @release_builder.build(release_id)
    request = release.fetch(:request)
    project_id = release.fetch(:project_id)
    artifact_io = release.fetch(:artifact_io)
    validate_public_release!(release_id, project_id, request, artifact_io)

    response = request_publish(release_id, project_id, request, artifact_io)
    validate_release_response!(
      response,
      release_id,
      require_published: true,
      expected_artifact_digest: request.fetch("artifact_digest"),
      expected_source_artifact_digest: request.fetch("source_artifact_digest")
    )
  ensure
    close_artifact_io(artifact_io) if defined?(artifact_io) && artifact_io
  end

  def status(release_id)
    validate_release_id!(release_id)
    response = request_v1("status", release_id)
    validate_release_response!(response, release_id, require_published: false)
  end

  private

  def validate_release_id!(release_id)
    raise PrivateSitePublisherClientError, "publication did not complete" unless RELEASE_ID.match?(release_id.to_s)
  end

  def validate_public_release!(release_id, project_id, request, artifact_io)
    raise PrivateSitePublisherClientError, "publication did not complete" unless project_id.is_a?(String)
    raise PrivateSitePublisherClientError, "publication did not complete" unless request.is_a?(Hash)
    raise PrivateSitePublisherClientError, "publication did not complete" unless request.fetch("publication_id") == release_id
    raise PrivateSitePublisherClientError, "publication did not complete" unless request.fetch("project_id") == project_id
    raise PrivateSitePublisherClientError, "publication did not complete" unless artifact_io.respond_to?(:stat) && artifact_io.respond_to?(:to_io) && artifact_io.stat.file?
  rescue KeyError, TypeError
    raise PrivateSitePublisherClientError, "publication did not complete"
  end

  def request_v1(action, release_id = nil)
    payload = { "schema_version" => 1, "action" => action }
    payload["release_id"] = release_id if release_id
    with_socket do |socket|
      socket.write(JSON.generate(payload) + "\n")
      read_response(socket)
    end
  end

  def request_publish(release_id, project_id, request, artifact_io)
    payload = {
      "schema_version" => 2,
      "action" => "publish",
      "release_id" => release_id,
      "project_id" => project_id,
      "request" => request
    }
    with_socket do |socket|
      socket.write(JSON.generate(payload) + "\n")
      artifact_io.rewind
      socket.send_io(artifact_io.to_io)
      read_response(socket)
    end
  end

  def with_socket
    socket = nil
    Timeout.timeout(RESPONSE_TIMEOUT_SECONDS) do
      socket = UNIXSocket.new(@socket_path)
      return yield(socket)
    end
  rescue Errno::ENOENT, Errno::ECONNREFUSED, Errno::EACCES, Errno::EPIPE, Errno::ECONNRESET, Errno::ECONNABORTED, SocketError, IOError, Timeout::Error, JSON::ParserError
    raise PrivateSitePublisherClientError, "publication did not complete"
  ensure
    socket&.close unless socket&.closed?
  end

  def read_response(socket)
    raw = socket.gets(MAX_RESPONSE_BYTES + 1)
    raise PrivateSitePublisherClientError, "publication did not complete" unless raw && raw.end_with?("\n") && raw.bytesize <= MAX_RESPONSE_BYTES
    response = JSON.parse(raw.to_s)
    raise PrivateSitePublisherClientError, "publication did not complete" unless response.is_a?(Hash)
    raise PrivateSitePublisherClientError, "publication did not complete" if response["result"] == "error"

    response
  end

  def validate_release_response!(response, release_id, require_published:, expected_artifact_digest: nil, expected_source_artifact_digest: nil)
    raise PrivateSitePublisherClientError, "publication did not complete" unless response.is_a?(Hash)
    raise PrivateSitePublisherClientError, "publication did not complete" unless response.fetch("schema_version") == 1
    raise PrivateSitePublisherClientError, "publication did not complete" unless response.fetch("publication_id") == release_id
    raise PrivateSitePublisherClientError, "publication did not complete" unless SITE_IDS.include?(response.fetch("site_id"))

    allowed = %w[schema_version publication_id site_id state attempts artifact_digest source_artifact_digest verified_at failed_at result failure updated_at]
    raise PrivateSitePublisherClientError, "publication did not complete" unless (response.keys - allowed).empty?
    if require_published
      published = response.fetch("result") == "published" && response.fetch("state") == "verified"
      raise PrivateSitePublisherClientError, "publication did not complete" unless published
      raise PrivateSitePublisherClientError, "publication did not complete" unless response.fetch("artifact_digest") == expected_artifact_digest
      raise PrivateSitePublisherClientError, "publication did not complete" unless response.fetch("source_artifact_digest") == expected_source_artifact_digest
    end
    response
  rescue KeyError, TypeError
    raise PrivateSitePublisherClientError, "publication did not complete"
  end

  def close_artifact_io(artifact_io)
    artifact_io.close unless artifact_io.closed?
    artifact_io.unlink if artifact_io.respond_to?(:unlink)
  rescue IOError, SystemCallError
    nil
  end
end

# This builder is intentionally public and unprivileged.  It can only read an
# already-created receipt/snapshot from a registered project workspace.  Even a
# path race here cannot grant access to the protected service account or its
# deployment identity; the protected service receives only the resulting file
# descriptor and extracts it under its own private root.
class PublicReleaseArchiveBuilder
  MAX_ARCHIVE_BYTES = 100 * 1024 * 1024
  MAX_FILES = 10_000
  REQUIRED_REQUEST_KEYS = %w[schema_version publication_id created_at project_id site_id preflight_id artifact_digest source_artifact_digest file_count total_bytes execution].freeze

  def initialize(root: Pathname.new(__dir__).join("../../../..").expand_path.cleanpath)
    @root = Pathname.new(root).expand_path.cleanpath
  end

  def build(release_id)
    validate_release_id!(release_id)
    project_id, workspace = locate_registered_release!(release_id)
    request = read_public_request!(workspace, release_id)
    validate_request!(request, release_id, project_id)
    artifact = public_artifact_directory!(workspace, release_id)
    archive = build_archive!(artifact)
    { project_id: project_id, request: request, artifact_io: archive }
  rescue PrivateSitePublisherClientError
    raise
  rescue StandardError
    raise PrivateSitePublisherClientError, "publication did not complete"
  end

  private

  def validate_release_id!(release_id)
    raise PrivateSitePublisherClientError, "publication did not complete" unless PrivateSitePublisherClient::RELEASE_ID.match?(release_id.to_s)
  end

  def locate_registered_release!(release_id)
    registry_path = @root.join("registries/projects_registry.yaml")
    registry = YAML.safe_load(registry_path.read(encoding: "UTF-8"), permitted_classes: [], aliases: false)
    raise PrivateSitePublisherClientError, "publication did not complete" unless registry.is_a?(Hash)
    projects = Array(registry.fetch("projects"))
    matches = projects.each_with_object([]) do |project, found|
      next unless project.is_a?(Hash)

      project_id = project["id"]
      raw_workspace = project["workspace"] || project["path"]
      next unless safe_project_id?(project_id) && safe_workspace?(raw_workspace)

      workspace = Pathname.new(raw_workspace).expand_path.cleanpath
      request_path = workspace.join("var", "server-ops", "publish-requests", "#{release_id}.json")
      next unless request_path.file? && !request_path.symlink?

      found << [project_id, workspace]
    end
    raise PrivateSitePublisherClientError, "publication did not complete" unless matches.length == 1

    matches.first
  rescue KeyError
    raise PrivateSitePublisherClientError, "publication did not complete"
  end

  def read_public_request!(workspace, release_id)
    request_path = workspace.join("var", "server-ops", "publish-requests", "#{release_id}.json")
    stat = request_path.lstat
    raise PrivateSitePublisherClientError, "publication did not complete" if stat.symlink? || !stat.file?

    flags = File::RDONLY
    flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
    File.open(request_path.to_s, flags) do |input|
      actual = input.stat
      unchanged = actual.file? && actual.dev == stat.dev && actual.ino == stat.ino && actual.size == stat.size
      raise PrivateSitePublisherClientError, "publication did not complete" unless unchanged

      JSON.parse(input.read)
    end
  rescue Errno::ELOOP
    raise PrivateSitePublisherClientError, "publication did not complete"
  end

  def validate_request!(request, release_id, project_id)
    raise PrivateSitePublisherClientError, "publication did not complete" unless request.is_a?(Hash) && request.keys.sort == REQUIRED_REQUEST_KEYS.sort
    raise PrivateSitePublisherClientError, "publication did not complete" unless request.fetch("schema_version") == 2
    raise PrivateSitePublisherClientError, "publication did not complete" unless request.fetch("publication_id") == release_id && request.fetch("project_id") == project_id
    raise PrivateSitePublisherClientError, "publication did not complete" unless PrivateSitePublisherClient::SITE_IDS.include?(request.fetch("site_id"))
  rescue KeyError, TypeError
    raise PrivateSitePublisherClientError, "publication did not complete"
  end

  def public_artifact_directory!(workspace, release_id)
    artifact = workspace.join("var", "server-ops", "publish-staging", release_id, "artifact")
    ensure_directory_within_root!(workspace, artifact)
    artifact
  end

  def build_archive!(artifact)
    archive = Tempfile.new(["two-head-wu-release-", ".tar"])
    archive.binmode
    count = 0
    Gem::Package::TarWriter.new(archive) do |tar|
      count = add_directory_to_archive!(tar, artifact, artifact, count)
    end
    archive.flush
    raise PrivateSitePublisherClientError, "publication did not complete" if archive.size <= 0 || archive.size > MAX_ARCHIVE_BYTES

    archive.rewind
    archive
  rescue StandardError
    archive&.close!
    raise
  end

  def add_directory_to_archive!(tar, root, directory, count)
    ensure_directory_within_root!(root, directory)
    Dir.children(directory).sort.each do |name|
      source_path = directory.join(name)
      relative = source_path.relative_path_from(root).to_s
      validate_archive_relative_path!(relative)
      stat = source_path.lstat
      raise PrivateSitePublisherClientError, "publication did not complete" if stat.symlink?
      count += 1
      raise PrivateSitePublisherClientError, "publication did not complete" if count > MAX_FILES

      if stat.directory?
        ensure_directory_within_root!(root, source_path)
        tar.mkdir(relative, 0o755)
        count = add_directory_to_archive!(tar, root, source_path, count)
      elsif stat.file?
        add_file_to_archive!(tar, source_path, relative, stat)
      else
        raise PrivateSitePublisherClientError, "publication did not complete"
      end
    end
    count
  rescue Errno::ENOENT, Errno::EACCES
    raise PrivateSitePublisherClientError, "publication did not complete"
  end

  def add_file_to_archive!(tar, source_path, relative, expected_stat)
    flags = File::RDONLY
    flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
    File.open(source_path.to_s, flags) do |input|
      actual = input.stat
      unchanged = actual.file? && actual.dev == expected_stat.dev && actual.ino == expected_stat.ino && actual.size == expected_stat.size
      raise PrivateSitePublisherClientError, "publication did not complete" unless unchanged

      tar.add_file_simple(relative, 0o644, actual.size) { |output| IO.copy_stream(input, output) }
    end
  rescue Errno::ELOOP
    raise PrivateSitePublisherClientError, "publication did not complete"
  end

  def ensure_directory_within_root!(root, candidate)
    stat = candidate.lstat
    raise PrivateSitePublisherClientError, "publication did not complete" if stat.symlink? || !stat.directory?
    resolved_root = Pathname.new(File.realpath(root.to_s)).cleanpath
    resolved = Pathname.new(File.realpath(candidate.to_s)).cleanpath
    prefix = "#{resolved_root}#{File::SEPARATOR}"
    raise PrivateSitePublisherClientError, "publication did not complete" unless resolved == resolved_root || resolved.to_s.start_with?(prefix)
  rescue Errno::ENOENT, Errno::EACCES
    raise PrivateSitePublisherClientError, "publication did not complete"
  end

  def validate_archive_relative_path!(value)
    components = value.to_s.split(File::SEPARATOR)
    invalid = value.start_with?(File::SEPARATOR) || value.include?("\0") || components.empty? || components.any? { |part| part.empty? || part == "." || part == ".." || part.include?("\\") }
    raise PrivateSitePublisherClientError, "publication did not complete" if invalid
  end

  def safe_project_id?(value)
    value.is_a?(String) && value.match?(/\A[a-z0-9][a-z0-9-]{0,62}\z/)
  end

  def safe_workspace?(value)
    value.is_a?(String) && value.start_with?(File::SEPARATOR) && !value.include?("\0")
  end
end
