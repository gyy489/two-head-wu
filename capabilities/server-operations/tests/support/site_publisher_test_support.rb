#!/usr/bin/env ruby
# frozen_string_literal: true

# Test-only fixtures for the protected static-site publisher.  They deliberately
# never open a network connection or inspect an SSH/configuration file outside a
# temporary directory created by the test process.

require "digest"
require "fileutils"
require "json"
require "pathname"
require "rubygems/package"
require "securerandom"
require "socket"
require "tempfile"
require "time"

module SitePublisherTestSupport
  module_function

  def assert(condition, message)
    raise message unless condition
  end

  def assert_raises(error_class, message = nil)
    raised = false
    begin
      yield
    rescue error_class
      raised = true
    end
    raise(message || "expected #{error_class}") unless raised
  end

  def artifact_report(root)
    root = Pathname.new(root)
    digest = Digest::SHA256.new
    report = { "file_count" => 0, "total_bytes" => 0 }
    scan_artifact(root, root, digest, report)
    report.merge("artifact_digest" => digest.hexdigest)
  end

  def scan_artifact(root, directory, digest, report)
    Dir.children(directory).sort.each do |name|
      path = directory.join(name)
      relative = path.relative_path_from(root).to_s
      stat = path.lstat
      raise "fixture artifact unexpectedly contains a symbolic link" if stat.symlink?

      if stat.directory?
        digest.update("D\0#{relative}\0")
        scan_artifact(root, path, digest, report)
      elsif stat.file?
        file_digest = Digest::SHA256.file(path.to_s).hexdigest
        digest.update("F\0#{relative}\0#{stat.size}\0#{file_digest}\0")
        report["file_count"] += 1
        report["total_bytes"] += stat.size
      else
        raise "fixture artifact unexpectedly contains an unsupported entry"
      end
    end
  end

  def write_secure_file(path, content)
    path = Pathname.new(path)
    FileUtils.mkdir_p(path.dirname, mode: 0o700)
    File.chmod(0o700, path.dirname)
    File.open(path.to_s, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(content) }
    File.chmod(0o600, path)
  end

  # Build the same regular-file archive the unprivileged client hands to the
  # protected service.  The test service must receive this open descriptor;
  # it must never walk a project workspace itself.
  def archive_from_artifact(artifact)
    artifact = Pathname.new(artifact)
    archive = Tempfile.new(["two-head-wu-artifact-", ".tar"])
    archive.binmode
    Gem::Package::TarWriter.new(archive) do |tar|
      write_artifact_tree_to_tar!(tar, artifact, artifact)
    end
    archive.flush
    archive.rewind
    archive
  end

  # Deliberately allows a test to construct a malformed archive entry.  This
  # is only used to prove that the protected extractor rejects it before any
  # fixed transport is reached.
  def archive_with_file(path, content)
    archive = Tempfile.new(["two-head-wu-malformed-", ".tar"])
    archive.binmode
    Gem::Package::TarWriter.new(archive) do |tar|
      tar.add_file_simple(path, 0o644, content.bytesize) { |output| output.write(content) }
    end
    archive.flush
    archive.rewind
    archive
  end

  def write_artifact_tree_to_tar!(tar, root, directory)
    Dir.children(directory).sort.each do |name|
      source = directory.join(name)
      relative = source.relative_path_from(root).to_s
      stat = source.lstat
      raise "fixture artifact unexpectedly contains a symbolic link" if stat.symlink?

      if stat.directory?
        tar.mkdir(relative, 0o755)
        write_artifact_tree_to_tar!(tar, root, source)
      elsif stat.file?
        tar.add_file_simple(relative, 0o644, stat.size) do |output|
          File.open(source.to_s, "rb") { |input| IO.copy_stream(input, output) }
        end
      else
        raise "fixture artifact unexpectedly contains an unsupported entry"
      end
    end
  end
  private_class_method :write_artifact_tree_to_tar!

  # Represents the fixed private target without communicating with one.  The first
  # publication attempt fails so a test can prove the service retries automatically.
  class FlakyFixtureTransport
    attr_reader :attempts, :received_snapshots, :received_targets, :received_snapshot_permissions

    def initialize(destination, failures: 1)
      @destination = Pathname.new(destination)
      @failures_remaining = failures
      @attempts = 0
      @received_snapshots = []
      @received_targets = []
      @received_snapshot_permissions = []
    end

    def publish(snapshot:, target:, private_root:)
      @attempts += 1
      @received_snapshots << Pathname.new(snapshot)
      @received_targets << target.dup
      @received_snapshot_permissions << static_snapshot_permissions?(snapshot)
      SitePublisherTestSupport.assert(Pathname.new(private_root).directory?, "fixture did not receive a protected private root")

      if @failures_remaining.positive?
        @failures_remaining -= 1
        raise PrivateSitePublisherError, "upload attempt failed"
      end

      FileUtils.mkdir_p(@destination.to_s, mode: 0o755)
      Dir.children(snapshot).sort.each do |name|
        FileUtils.cp_r(Pathname.new(snapshot).join(name).to_s, @destination.join(name).to_s, preserve: true)
      end
    end

    private

    def static_snapshot_permissions?(snapshot)
      snapshot = Pathname.new(snapshot)
      return false unless (snapshot.stat.mode & 0o777) == 0o755

      Dir.glob(File.join(snapshot.to_s, "**", "*"), File::FNM_DOTMATCH).all? do |entry|
        basename = File.basename(entry)
        next true if basename == "." || basename == ".."

        stat = File.lstat(entry)
        expected_mode = stat.directory? ? 0o755 : 0o644
        (stat.mode & 0o777) == expected_mode
      end
    rescue SystemCallError
      false
    end
  end

  # A verifier which reads only the fake transport destination.  This makes the
  # release-marker assertion deterministic and proves what the service passed into
  # verification without issuing any HTTP request.
  class FixtureReleaseVerifier
    attr_reader :calls

    def initialize(destination)
      @destination = Pathname.new(destination)
      @calls = []
    end

    def verify(verification_url:, publication_id:, site_id:, artifact_digest:, source_artifact_digest:)
      @calls << {
        "verification_url" => verification_url,
        "publication_id" => publication_id,
        "site_id" => site_id,
        "artifact_digest" => artifact_digest,
        "source_artifact_digest" => source_artifact_digest
      }
      marker = JSON.parse(@destination.join(".two-head-wu-release.json").read(encoding: "UTF-8"))
      SitePublisherTestSupport.assert(verification_url.start_with?("https://"), "service did not use protected HTTPS verification URL")
      SitePublisherTestSupport.assert(marker.fetch("publication_id") == publication_id, "published marker publication ID mismatch")
      SitePublisherTestSupport.assert(marker.fetch("site_id") == site_id, "published marker site ID mismatch")
      SitePublisherTestSupport.assert(marker.fetch("source_artifact_digest") == source_artifact_digest, "published marker source digest mismatch")
      SitePublisherTestSupport.assert(artifact_digest.match?(/\A[0-9a-f]{64}\z/), "service did not supply an artifact digest")
      true
    end
  end

  # A local UNIX-socket endpoint used only to validate the public client protocol.
  # It is not a publisher and never invokes the service or a network target.
  class UnixSocketProtocolFixture
    attr_reader :socket_path, :requests, :received_archives

    def initialize(_directory)
      # macOS limits UNIX-domain socket paths to 104 bytes.  `Dir.mktmpdir`
      # intentionally generates long names, so keep the socket itself under the
      # short system temporary directory while retaining all fixture data in the
      # caller's isolated directory.
      @socket_path = File.join(Dir.tmpdir, "thw-#{Process.pid}-#{SecureRandom.hex(4)}.sock")
      @requests = []
      @received_archives = []
      @server = UNIXServer.new(@socket_path)
      @thread = nil
    end

    def serve(count:)
      @thread = Thread.new do
        count.times do
          connection = @server.accept
          payload = JSON.parse(connection.gets || "")
          @requests << payload
          receive_archive_if_present(connection, payload)
          response = response_for(payload)
          connection.write(JSON.generate(response) + "\n")
          connection.close
        end
      end
    end

    def close
      @server.close unless @server.closed?
      @thread&.join(2)
      File.unlink(@socket_path) if File.exist?(@socket_path)
    rescue Errno::ENOENT
      nil
    end

    private

    def receive_archive_if_present(connection, payload)
      return unless payload["schema_version"] == 2 && payload["action"] == "publish"

      archive = connection.recv_io(File)
      @received_archives << {
        "regular_file" => archive.stat.file?,
        "bytes" => archive.size,
        "header" => archive.read(512)
      }
    ensure
      archive&.close unless archive&.closed?
    end

    def response_for(payload)
      case payload.fetch("action")
      when "ready"
        { "schema_version" => 1, "result" => "ready" }
      when "status"
        {
          "schema_version" => 1,
          "publication_id" => payload.fetch("release_id"),
          "site_id" => "public-site",
          "state" => "verified",
          "artifact_digest" => "b" * 64,
          "attempts" => 2,
          "result" => "published"
        }
      when "publish"
        request = payload.fetch("request")
        {
          "schema_version" => 1,
          "publication_id" => payload.fetch("release_id"),
          "site_id" => "public-site",
          "state" => "verified",
          "artifact_digest" => request.fetch("artifact_digest"),
          "source_artifact_digest" => request.fetch("source_artifact_digest"),
          "attempts" => 2,
          "result" => "published"
        }
      else
        { "schema_version" => 1, "result" => "error", "error" => "request rejected" }
      end
    rescue KeyError
      { "schema_version" => 1, "result" => "error", "error" => "request rejected" }
    end
  end
end
