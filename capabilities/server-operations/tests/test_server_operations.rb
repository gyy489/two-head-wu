#!/usr/bin/env ruby
# frozen_string_literal: true

# Contract tests for the two-part personal static-site publisher.  They use
# only temporary files, a fake transport, and a local UNIX socket.  In
# particular, the protected service gets an already-open tar descriptor; it
# must never resolve a release path below a project workspace.

require "fileutils"
require "json"
require "open3"
require "pathname"
require "securerandom"
require "shellwords"
require "tmpdir"
require "time"
require "yaml"

require_relative "support/site_publisher_test_support"

ROOT = File.expand_path("../../..", __dir__)
ADAPTER = File.join(ROOT, "capabilities/server-operations/adapters/server-operations")
PRIVATE_RUNNER = File.join(ROOT, "capabilities/server-operations/private-runner/site-publisher")
PRIVATE_SERVICE_RUNNER = File.join(ROOT, "capabilities/server-operations/private-runner/site-publisher-service")
PRIVATE_CLIENT_LIBRARY = File.join(ROOT, "capabilities/server-operations/private-runner/lib/private_site_publisher_client")
PRIVATE_SERVICE_LIBRARY = File.join(ROOT, "capabilities/server-operations/private-runner/lib/private_site_publisher")

require PRIVATE_CLIENT_LIBRARY
require PRIVATE_SERVICE_LIBRARY

def assert(condition, message)
  SitePublisherTestSupport.assert(condition, message)
end

def assert_raises(error_class, message = nil, &block)
  SitePublisherTestSupport.assert_raises(error_class, message, &block)
end

def invoke(command, env = {}, *arguments)
  Open3.capture3(env, command, *arguments)
end

def output_value(output, key)
  line = output.lines.find { |item| item.start_with?("#{key}: ") }
  raise "missing #{key} in command output" unless line

  line.split(": ", 2).last.strip
end

def assert_rejected(message)
  value = yield
  rejected = value.is_a?(Hash) && %w[error rejected].include?(value["result"] || value["status"])
  assert(rejected, message)
rescue PrivateSitePublisherError
  # A local service API may reject either by raising its public error or by
  # returning a redacted error response for its socket caller.
  true
end

def write_json(path, value)
  SitePublisherTestSupport.write_secure_file(path, JSON.pretty_generate(value) + "\n")
end

def secure_tree(path)
  FileUtils.mkdir_p(path.to_s, mode: 0o700)
  File.chmod(0o700, path.to_s)
end

def deep_copy(value)
  JSON.parse(JSON.generate(value))
end

def protected_config(workspace:, public_temp_url: "https://verification.example.test/public-site/")
  {
    "schema_version" => 3,
    "projects" => {
      "two-head-wu" => {
        "workspace" => workspace.to_s,
        "allowed_sites" => ["public-site"]
      }
    },
    "targets" => {
      "private-site" => {
        "transport" => "rsync_ssh",
        "ssh_target" => "deploy@private-site-target",
        "remote_root" => "/srv/sites/private-site",
        "delete_policy" => "mirror",
        "verification" => "https-release-marker",
        "verification_url" => "https://verification.example.test/private-site/"
      },
      "public-site" => {
        "transport" => "rsync_ssh",
        "ssh_target" => "deploy@public-site-target",
        "remote_root" => "/srv/sites/public-site",
        "delete_policy" => "mirror",
        "verification" => "https-release-marker",
        "verification_url" => public_temp_url
      }
    }
  }
end

def make_service_fixture(temporary_root, created_at: Time.now.utc)
  fixture_root = Pathname.new(temporary_root)
  root = fixture_root.join("public-workspace")
  private_root = fixture_root.join("protected-service-state")
  secure_tree(root)
  secure_tree(private_root)

  release_id = "publish-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-public-site-#{SecureRandom.hex(4)}"
  request_directory = root.join("var/server-ops/publish-requests")
  artifact = root.join("var/server-ops/publish-staging/#{release_id}/artifact")
  secure_tree(request_directory)
  secure_tree(artifact)
  File.open(artifact.join("index.html").to_s, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
    file.write("<h1>frozen release fixture</h1>\n")
  end

  # This is the source-artifact digest before the release marker is added.
  # It must bind the eventual marker and HTTPS verification to the source.
  source_artifact_digest = SitePublisherTestSupport.artifact_report(artifact).fetch("artifact_digest")
  marker = {
    "schema_version" => 2,
    "publication_id" => release_id,
    "site_id" => "public-site",
    "prepared_at" => created_at.utc.iso8601,
    "source_artifact_digest" => source_artifact_digest
  }
  File.open(artifact.join(".two-head-wu-release.json").to_s, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
    file.write(JSON.generate(marker) + "\n")
  end
  artifact_report = SitePublisherTestSupport.artifact_report(artifact)
  request = {
    "schema_version" => 2,
    "publication_id" => release_id,
    "created_at" => created_at.utc.iso8601,
    "project_id" => "two-head-wu",
    "site_id" => "public-site",
    "preflight_id" => "preflight-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-public-site-#{SecureRandom.hex(4)}",
    "source_artifact_digest" => source_artifact_digest,
    "artifact_digest" => artifact_report.fetch("artifact_digest"),
    "file_count" => artifact_report.fetch("file_count"),
    "total_bytes" => artifact_report.fetch("total_bytes"),
    "execution" => "codex-driven-protected-executor"
  }
  request_path = request_directory.join("#{release_id}.json")
  write_json(request_path, request)

  # These project-owned files are intentionally malformed.  A protected
  # service must not consult them when it receives an archive FD and a request
  # envelope; only its protected configuration determines targets.
  public_catalog = root.join("catalog/deployments/personal-static-sites.yaml")
  FileUtils.mkdir_p(public_catalog.dirname.to_s, mode: 0o700)
  File.write(public_catalog, "this is intentionally not trusted YAML: [\n", encoding: "UTF-8")
  public_registry = root.join("registries/projects_registry.yaml")
  FileUtils.mkdir_p(public_registry.dirname.to_s, mode: 0o700)
  File.write(public_registry, "this is intentionally not trusted YAML: [\n", encoding: "UTF-8")

  config_path = private_root.join("site-publisher.yaml")
  SitePublisherTestSupport.write_secure_file(config_path, YAML.dump(protected_config(workspace: root)))

  {
    root: root,
    private_root: private_root,
    workspace: root,
    release_id: release_id,
    request_path: request_path,
    artifact: artifact,
    request: request,
    source_artifact_digest: source_artifact_digest,
    artifact_report: artifact_report,
    config_path: config_path
  }
end

def read_protected_config(fixture)
  YAML.safe_load(fixture.fetch(:config_path).read(encoding: "UTF-8"), permitted_classes: [], aliases: false)
end

def write_protected_config(fixture, config)
  SitePublisherTestSupport.write_secure_file(fixture.fetch(:config_path), YAML.dump(config))
end

def assert_readable_upload_snapshot(snapshot)
  snapshot = Pathname.new(snapshot)
  assert((snapshot.stat.mode & 0o777) == 0o755, "service upload snapshot directory is not readable by a static web deploy user")
  Dir.glob(File.join(snapshot.to_s, "**", "*"), File::FNM_DOTMATCH).each do |entry|
    basename = File.basename(entry)
    next if basename == "." || basename == ".."

    stat = File.lstat(entry)
    expected_mode = stat.directory? ? 0o755 : 0o644
    assert((stat.mode & 0o777) == expected_mode, "service upload snapshot has unsafe static-file permissions")
  end
end

def assert_redacted_result(result)
  serialized = JSON.generate(result)
  %w[ssh_target remote_root verification_url private_root ssh_config id_ed25519].each do |private_field|
    assert(!serialized.include?(private_field), "service result leaked #{private_field}")
  end
end

def build_service(fixture, transport:, verifier:)
  PrivateSitePublisherService.new(
    root: fixture.fetch(:root),
    private_root: fixture.fetch(:private_root),
    transport: transport,
    verifier: verifier,
    sleeper: ->(_seconds) {}
  )
end

# The public-client/service boundary is a schema-2 envelope plus an open,
# regular tar descriptor.  Keep this helper deliberately outside the service:
# calling it is how each test proves the protected side gets no project path.
def publish_from_archive(service, fixture, request: fixture.fetch(:request), release_id: fixture.fetch(:release_id), project_id: "two-head-wu", archive: nil)
  own_archive = archive.nil?
  archive ||= SitePublisherTestSupport.archive_from_artifact(fixture.fetch(:artifact))
  envelope = {
    "schema_version" => 2,
    "action" => "publish",
    "release_id" => release_id,
    "project_id" => project_id,
    "request" => request
  }
  archive.rewind if archive.respond_to?(:rewind)
  service.handle_request(envelope, artifact_io: archive)
ensure
  archive.close! if own_archive && archive && !archive.closed?
end

def expect_config_rejected(temporary_root)
  fixture = make_service_fixture(temporary_root)
  config = read_protected_config(fixture)
  yield config, fixture
  write_protected_config(fixture, config) if File.exist?(fixture.fetch(:config_path))
  transport = SitePublisherTestSupport::FlakyFixtureTransport.new(Pathname.new(temporary_root).join("should-not-publish"), failures: 0)
  verifier = SitePublisherTestSupport::FixtureReleaseVerifier.new(Pathname.new(temporary_root).join("should-not-verify"))
  service = build_service(fixture, transport: transport, verifier: verifier)
  assert_rejected("service accepted an unsafe protected target configuration") { publish_from_archive(service, fixture) }
  assert(transport.attempts.zero?, "service reached the transport after rejecting configuration")
end

def test_public_adapter_creates_only_a_frozen_release
  adapter_source = File.read(ADAPTER, encoding: "UTF-8")
  assert(!adapter_source.match?(/require\s+["'](?:open3|net\/http|socket)["']|Open3\.|Net::HTTP|\bsystem\s*\(|\bexec\s*\(|\bspawn\s*\(/), "public adapter has an execution or network path")
  assert(!adapter_source.include?("TWO_HEAD_WU_PRIVATE_ROOT"), "public adapter accepts a private-root environment override")

  nonce = "test-publish-#{Process.pid}-#{SecureRandom.hex(6)}"
  project_registry = YAML.safe_load(
    Pathname.new(ROOT).join("registries/projects_registry.yaml").read(encoding: "UTF-8"),
    permitted_classes: [], aliases: false
  )
  registered_project = project_registry.fetch("projects").find { |item| item.fetch("id") == "two-head-wu" }
  registered_root = Pathname.new(registered_project.fetch("path"))
  source_parent = registered_root.join("var/server-ops/#{nonce}")
  source = source_parent.join("dist")
  generated_paths = [source_parent]
  begin
    FileUtils.mkdir_p(source.to_s, mode: 0o700)
    File.write(source.join("index.html"), "<h1>immutable artifact</h1>\n", encoding: "UTF-8")
    environment = {
      "TWO_HEAD_WU_PRIVATE_ROOT" => "/caller-controlled-private-root-must-be-ignored",
      "HTTP_PROXY" => "http://caller-controlled-proxy.invalid",
      "HTTPS_PROXY" => "http://caller-controlled-proxy.invalid"
    }

    stdout, stderr, status = invoke(ADAPTER, environment, "health")
    assert(status.success?, "adapter health failed: #{stderr}")
    assert(stdout.include?("resources: 4"), "adapter health did not report the registered machines")
    assert(stdout.include?("sites:     2"), "adapter health did not report the registered sites")

    stdout, stderr, status = invoke(ADAPTER, environment, "preflight", "--project", "two-head-wu", "--site", "public-site", "--source", source.to_s)
    assert(status.success?, "adapter preflight failed: #{stderr}")
    preflight_path = registered_root.join(output_value(stdout, "receipt"))
    generated_paths << preflight_path
    preflight = JSON.parse(preflight_path.read(encoding: "UTF-8"))
    assert(preflight.fetch("network_access") == "none", "preflight claims network access")
    assert(preflight.fetch("artifact_digest").match?(/\A[0-9a-f]{64}\z/), "preflight has no content digest")
    assert((preflight_path.stat.mode & 0o077).zero?, "preflight receipt is too broadly readable")
    assert(!preflight_path.read(encoding: "UTF-8").include?(source.to_s), "preflight receipt leaked source path")

    stdout, stderr, status = invoke(ADAPTER, environment, "publish", "--project", "two-head-wu", "--site", "public-site", "--source", source.to_s)
    assert(status.success?, "adapter publication preparation failed: #{stderr}")
    release_id = output_value(stdout, "publication_id")
    assert(release_id.match?(PrivateSitePublisherService::RELEASE_ID), "adapter issued an invalid release ID")
    assert(stdout.include?("private-site-publisher publish --release #{release_id}"), "adapter did not give the fixed publisher handoff")
    request_path = registered_root.join(output_value(stdout, "request"))
    generated_paths << request_path
    snapshot = registered_root.join("var/server-ops/publish-staging/#{release_id}")
    generated_paths << snapshot
    request = JSON.parse(request_path.read(encoding: "UTF-8"))
    generated_paths << registered_root.join("var/server-ops/preflights/#{request.fetch('preflight_id')}.json")
    marker = JSON.parse(snapshot.join("artifact/.two-head-wu-release.json").read(encoding: "UTF-8"))
    snapshot_report = SitePublisherTestSupport.artifact_report(snapshot.join("artifact"))
    assert(request.fetch("schema_version") == 2, "publication request did not use the protected-executor schema")
    assert(request.fetch("source_artifact_digest") == preflight.fetch("artifact_digest"), "request lost source digest binding")
    assert(marker.fetch("source_artifact_digest") == preflight.fetch("artifact_digest"), "release marker lost source digest binding")
    assert(request.fetch("artifact_digest") == snapshot_report.fetch("artifact_digest"), "request does not bind the frozen snapshot")
    assert(!request_path.read(encoding: "UTF-8").include?(source.to_s), "publication request leaked source path")
    assert((request_path.stat.mode & 0o077).zero?, "publication request is too broadly readable")

    File.write(source.join("index.html"), "<h1>changed after preparation</h1>\n", encoding: "UTF-8")
    frozen_html = snapshot.join("artifact/index.html").read(encoding: "UTF-8")
    assert(frozen_html.include?("immutable artifact"), "frozen release changed with its source directory")

    _stdout, _stderr, status = invoke(ADAPTER, environment, "publish", "--project", "two-head-wu", "--site", "public-site", "--source", source.to_s, "--approve")
    assert(!status.success?, "legacy --approve option was accepted")
  ensure
    generated_paths.reverse_each do |path|
      next unless path.exist? || path.symlink?

      FileUtils.remove_entry_secure(path.to_s)
    end
  end
end

class FixedArchiveReleaseBuilder
  def initialize(release_id:, project_id:, request:, artifact:)
    @release_id = release_id
    @project_id = project_id
    @request = request
    @artifact = artifact
  end

  def build(release_id)
    raise PrivateSitePublisherClientError, "publication did not complete" unless release_id == @release_id

    {
      project_id: @project_id,
      request: deep_copy(@request),
      artifact_io: SitePublisherTestSupport.archive_from_artifact(@artifact)
    }
  end
end

def test_fixed_socket_client_protocol
  client_source = File.read(PRIVATE_CLIENT_LIBRARY + ".rb", encoding: "UTF-8")
  cli_source = File.read(PRIVATE_RUNNER, encoding: "UTF-8")
  service_cli_source = File.read(PRIVATE_SERVICE_RUNNER, encoding: "UTF-8")
  assert(client_source.include?("DEFAULT_SOCKET_PATH"), "client does not define a fixed protected socket")
  assert(client_source.include?("send_io"), "client does not transfer the archive as a file descriptor")
  assert(!client_source.include?("ENV["), "client accepts environment-controlled connection data")
  assert(!client_source.match?(/ssh_config|id_ed25519|remote_root|verification_url/), "client contains private executor configuration")
  assert(!cli_source.match?(/--(?:socket|config|host|source|target|remote-root|ssh)/), "CLI exposes a caller-controlled publisher boundary")
  assert(File.executable?(PRIVATE_RUNNER), "public publisher client is not executable")
  assert(File.executable?(PRIVATE_SERVICE_RUNNER), "protected publisher service source is not executable")
  assert(service_cli_source.include?("UNIXServer"), "protected service has no fixed UNIX-socket entry point")
  assert(service_cli_source.include?("recv_io"), "protected service does not receive an archive descriptor")
  assert(service_cli_source.include?("DEFAULT_SOCKET_PATH") && service_cli_source.include?("DEFAULT_PRIVATE_ROOT"), "protected service does not define fixed installation boundaries")
  assert(!service_cli_source.include?("ENV["), "protected service command accepts environment-controlled boundaries")
  assert(!service_cli_source.match?(/--(?:socket|config|host|source|target|remote-root|ssh|private-root|root)/), "protected service exposes caller-controlled boundaries")

  Dir.mktmpdir("two-head-wu-client-protocol-") do |directory|
    release_fixture = make_service_fixture(directory)
    fixture = SitePublisherTestSupport::UnixSocketProtocolFixture.new(directory)
    fixture.serve(count: 3)
    begin
      release_id = release_fixture.fetch(:release_id)
      builder = FixedArchiveReleaseBuilder.new(
        release_id: release_id,
        project_id: "two-head-wu",
        request: release_fixture.fetch(:request),
        artifact: release_fixture.fetch(:artifact)
      )
      client = PrivateSitePublisherClient.new(socket_path: fixture.socket_path, release_builder: builder)
      assert(client.ready? == true, "client did not accept a valid ready response")
      status = client.status(release_id)
      result = client.publish(release_id)
      assert(status.fetch("result") == "published", "client did not return service status")
      assert(result.fetch("publication_id") == release_id, "client returned a result for another release")
      assert(result.fetch("result") == "published", "client did not return publication result")
      assert_redacted_result(result)
      assert(fixture.requests == [
        { "schema_version" => 1, "action" => "ready" },
        { "schema_version" => 1, "action" => "status", "release_id" => release_id },
        {
          "schema_version" => 2,
          "action" => "publish",
          "release_id" => release_id,
          "project_id" => "two-head-wu",
          "request" => release_fixture.fetch(:request)
        }
      ], "client sent a mutable or over-broad socket request")
      assert(fixture.received_archives.length == 1, "client did not send exactly one archive descriptor")
      assert(fixture.received_archives.fetch(0).fetch("regular_file"), "client sent a non-regular archive descriptor")
      assert(fixture.received_archives.fetch(0).fetch("bytes").positive?, "client sent an empty archive descriptor")
      assert(fixture.received_archives.fetch(0).fetch("header").bytesize.positive?, "client archive descriptor was unreadable")
    ensure
      fixture.close
    end
  end

  release_id = "publish-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-public-site-#{SecureRandom.hex(4)}"
  stdout, stderr, status = invoke(PRIVATE_RUNNER, { "TWO_HEAD_WU_PRIVATE_ROOT" => "/do-not-use", "HTTP_PROXY" => "http://do-not-use.invalid" }, "publish", "--release", release_id, "--config", "/not-allowed")
  assert(!status.success?, "CLI accepted a caller-provided config option")
  assert(stderr.include?("private site publication did not complete"), "CLI did not return a redacted failure")
  assert(!stdout.include?("do-not-use") && !stderr.include?("do-not-use"), "CLI echoed caller-controlled private input")
end

def test_bounded_transport_timeout_is_retry_compatible
  Dir.mktmpdir("two-head-wu-bounded-upload-") do |directory|
    marker = Pathname.new(directory).join("child-survived")
    transport_class = PrivateSitePublisherService::RsyncSshTransport
    original_timeout = transport_class.const_get(:TOTAL_UPLOAD_TIMEOUT_SECONDS)
    original_grace = transport_class.const_get(:TERMINATION_GRACE_SECONDS)
    transport_class.send(:remove_const, :TOTAL_UPLOAD_TIMEOUT_SECONDS)
    transport_class.const_set(:TOTAL_UPLOAD_TIMEOUT_SECONDS, 1)
    transport_class.send(:remove_const, :TERMINATION_GRACE_SECONDS)
    transport_class.const_set(:TERMINATION_GRACE_SECONDS, 1)

    began = Time.now
    begin
      transport = transport_class.new
      assert_raises(PrivateSitePublisherError, "bounded upload timeout did not return a retry-compatible error") do
        transport.send(
          :run_bounded_command!,
          { "PATH" => "/usr/bin:/bin" },
          ["/bin/sh", "-c", "trap '' TERM; /bin/sleep 8; /usr/bin/touch #{Shellwords.shellescape(marker.to_s)}"]
        )
      end
      assert(Time.now - began < 5, "bounded upload timeout did not terminate its process group")
      sleep 1
      assert(!marker.exist?, "timed-out upload child survived after its process group was terminated")
    ensure
      transport_class.send(:remove_const, :TOTAL_UPLOAD_TIMEOUT_SECONDS)
      transport_class.const_set(:TOTAL_UPLOAD_TIMEOUT_SECONDS, original_timeout)
      transport_class.send(:remove_const, :TERMINATION_GRACE_SECONDS)
      transport_class.const_set(:TERMINATION_GRACE_SECONDS, original_grace)
    end
  end
end

def test_protected_service_behavior
  service_source = File.read(PRIVATE_SERVICE_LIBRARY + ".rb", encoding: "UTF-8")
  assert(!service_source.include?("ENV["), "protected service reads agent-controlled environment variables")
  assert(!service_source.include?("Net::HTTP.start"), "HTTPS verifier may inherit a proxy from Net::HTTP.start")
  explicitly_disables_proxy = service_source.match?(/Net::HTTP\.new\([\s\S]{0,160}?\bnil\b/) || service_source.include?("Net::HTTP::Proxy(nil, nil)") || service_source.include?("proxy_from_env = false")
  assert(explicitly_disables_proxy, "HTTPS verifier does not explicitly disable proxy discovery")
  assert(!service_source.include?("--protect-args"), "service uses an rsync flag unsupported by the local protected executor")
  assert(!service_source.include?("var/server-ops"), "protected service still references agent-writable release paths")
  assert(!service_source.include?("load_public_release!"), "protected service still loads a release from the project workspace")

  Dir.mktmpdir("two-head-wu-protected-publisher-") do |directory|
    fixture = make_service_fixture(directory)
    destination = Pathname.new(directory).join("published-public-site")
    transport = SitePublisherTestSupport::FlakyFixtureTransport.new(destination)
    verifier = SitePublisherTestSupport::FixtureReleaseVerifier.new(destination)
    service = build_service(fixture, transport: transport, verifier: verifier)

    # Package the public snapshot before replacing its entire release tree with
    # an invalid symlink.  A successful publish proves that no privileged code
    # re-walked an agent-writable project path after it received the archive FD.
    archive = SitePublisherTestSupport.archive_from_artifact(fixture.fetch(:artifact))
    repeat_archive = SitePublisherTestSupport.archive_from_artifact(fixture.fetch(:artifact))
    workspace_var = fixture.fetch(:workspace).join("var")
    FileUtils.remove_entry_secure(workspace_var.to_s)
    File.symlink("/definitely-not-a-two-head-wu-release", workspace_var.to_s)

    old_http_proxy = ENV["HTTP_PROXY"]
    old_https_proxy = ENV["HTTPS_PROXY"]
    ENV["HTTP_PROXY"] = "http://agent-tampering-proxy.invalid"
    ENV["HTTPS_PROXY"] = "http://agent-tampering-proxy.invalid"
    begin
      result = publish_from_archive(service, fixture, archive: archive)
      assert(result.fetch("result") == "published", "protected service did not publish the supplied archive")
      assert(result.fetch("attempts") == 2, "protected service did not retry the transient upload failure")
      assert(result.fetch("artifact_digest") == fixture.fetch(:artifact_report).fetch("artifact_digest"), "service returned wrong artifact digest")
      assert_redacted_result(result)
    ensure
      archive.close! unless archive.closed?
      ENV["HTTP_PROXY"] = old_http_proxy
      ENV["HTTPS_PROXY"] = old_https_proxy
    end
    assert(transport.attempts == 2, "fake transport retry count is wrong")
    assert(transport.received_snapshots.all? { |snapshot| !snapshot.to_s.start_with?(fixture.fetch(:root).to_s) }, "service uploaded directly from an agent-writable tree")
    assert(transport.received_snapshot_permissions.all?, "service upload snapshot has unsafe static-file permissions")
    assert(!transport.received_snapshots.last.exist?, "service retained a full static staging copy after a synchronous release")
    assert(destination.join("index.html").read(encoding: "UTF-8").include?("frozen release fixture"), "service did not upload the frozen artifact")
    verifier_call = verifier.calls.fetch(0)
    assert(verifier_call.fetch("verification_url") == "https://verification.example.test/public-site/", "service followed public Catalog verification metadata")
    assert(verifier_call.fetch("source_artifact_digest") == fixture.fetch(:source_artifact_digest), "service did not bind verification to the source digest")

    audit_path = fixture.fetch(:private_root).join("audit/#{fixture.fetch(:release_id)}.json")
    assert(audit_path.file?, "protected service did not persist a single-use audit record")
    assert((audit_path.stat.mode & 0o077).zero?, "protected audit is too broadly readable")
    assert_redacted_result(JSON.parse(audit_path.read(encoding: "UTF-8")))

    status = service.handle_request({ "schema_version" => 1, "action" => "status", "release_id" => fixture.fetch(:release_id) })
    assert(status.fetch("result") == "published", "status did not return the protected audit result")
    assert(status.fetch("publication_id") == fixture.fetch(:release_id), "status returned another release")
    assert_redacted_result(status)
    ready = service.handle_request({ "schema_version" => 1, "action" => "ready" })
    assert(ready.fetch("result") == "ready", "service did not report ready through its IPC handler")

    begin
      assert_rejected("service accepted a repeated publication ID") do
        publish_from_archive(service, fixture, archive: repeat_archive)
      end
    ensure
      repeat_archive.close! unless repeat_archive.closed?
    end
    assert(transport.attempts == 2, "service retried a previously completed release")
  end
end

def test_service_rejects_untrusted_inputs
  Dir.mktmpdir("two-head-wu-unsafe-request-") do |directory|
    fixture = make_service_fixture(directory)
    transport = SitePublisherTestSupport::FlakyFixtureTransport.new(Pathname.new(directory).join("no-upload"), failures: 0)
    verifier = SitePublisherTestSupport::FixtureReleaseVerifier.new(Pathname.new(directory).join("no-verify"))
    service = build_service(fixture, transport: transport, verifier: verifier)

    assert_rejected("release ID traversal reached the service") do
      publish_from_archive(service, fixture, release_id: "../../etc/passwd")
    end
    assert(transport.attempts.zero?, "release ID traversal reached transport")

    extra_field_request = deep_copy(fixture.fetch(:request))
    extra_field_request["remote_root"] = "/agent-controlled-escape"
    assert_rejected("service accepted an agent-injected request field") do
      publish_from_archive(service, fixture, request: extra_field_request)
    end
    assert(transport.attempts.zero?, "injected request reached transport")

    assert_rejected("service accepted an envelope project mismatch") do
      publish_from_archive(service, fixture, project_id: "another-project")
    end
    assert(transport.attempts.zero?, "project mismatch reached transport")

    stale_request = deep_copy(fixture.fetch(:request))
    stale_request["created_at"] = (Time.now.utc - (48 * 60 * 60)).iso8601
    assert_rejected("service accepted an expired release request") do
      publish_from_archive(service, fixture, request: stale_request)
    end
    assert(transport.attempts.zero?, "expired release reached transport")
  end

  Dir.mktmpdir("two-head-wu-tampered-archive-") do |directory|
    fixture = make_service_fixture(directory)
    File.write(fixture.fetch(:artifact).join("index.html"), "tampered after request\n", encoding: "UTF-8")
    transport = SitePublisherTestSupport::FlakyFixtureTransport.new(Pathname.new(directory).join("no-upload"), failures: 0)
    service = build_service(fixture, transport: transport, verifier: SitePublisherTestSupport::FixtureReleaseVerifier.new(Pathname.new(directory).join("no-verify")))
    assert_rejected("service accepted a changed archive whose digest no longer matches its request") do
      publish_from_archive(service, fixture)
    end
    assert(transport.attempts.zero?, "tampered archive reached transport")
  end

  Dir.mktmpdir("two-head-wu-unsafe-archive-path-") do |directory|
    fixture = make_service_fixture(directory)
    transport = SitePublisherTestSupport::FlakyFixtureTransport.new(Pathname.new(directory).join("no-upload"), failures: 0)
    service = build_service(fixture, transport: transport, verifier: SitePublisherTestSupport::FixtureReleaseVerifier.new(Pathname.new(directory).join("no-verify")))
    unsafe_archive = SitePublisherTestSupport.archive_with_file("../outside.html", "escape")
    begin
      assert_rejected("service accepted an archive path traversal") do
        publish_from_archive(service, fixture, archive: unsafe_archive)
      end
    ensure
      unsafe_archive.close! unless unsafe_archive.closed?
    end
    assert(transport.attempts.zero?, "unsafe archive path reached transport")
  end

  Dir.mktmpdir("two-head-wu-nonregular-archive-") do |directory|
    fixture = make_service_fixture(directory)
    transport = SitePublisherTestSupport::FlakyFixtureTransport.new(Pathname.new(directory).join("no-upload"), failures: 0)
    service = build_service(fixture, transport: transport, verifier: SitePublisherTestSupport::FixtureReleaseVerifier.new(Pathname.new(directory).join("no-verify")))
    reader, writer = IO.pipe
    envelope = {
      "schema_version" => 2,
      "action" => "publish",
      "release_id" => fixture.fetch(:release_id),
      "project_id" => "two-head-wu",
      "request" => fixture.fetch(:request)
    }
    begin
      assert_rejected("service accepted a non-regular archive descriptor") do
        service.handle_request(envelope, artifact_io: reader)
      end
    ensure
      reader.close unless reader.closed?
      writer.close unless writer.closed?
    end
    assert(transport.attempts.zero?, "non-regular archive descriptor reached transport")
  end
end

def test_verified_publish_does_not_retry_when_audit_write_fails
  Dir.mktmpdir("two-head-wu-verified-audit-failure-") do |directory|
    fixture = make_service_fixture(directory)
    destination = Pathname.new(directory).join("verified-output")
    transport = SitePublisherTestSupport::FlakyFixtureTransport.new(destination, failures: 0)
    verifier = SitePublisherTestSupport::FixtureReleaseVerifier.new(destination)
    service = build_service(fixture, transport: transport, verifier: verifier)
    service.define_singleton_method(:write_audit!) do |_result|
      raise PrivateSitePublisherError, "private publication state is unavailable"
    end

    result = publish_from_archive(service, fixture)
    assert(result.fetch("result") == "published", "verified upload was changed into a failed publication by audit storage")
    assert(transport.attempts == 1, "verified upload retried after only the audit write failed")
    assert(destination.join("index.html").file?, "verified upload did not reach the fixed target fixture")
  end
end

def test_service_rejects_unsafe_protected_configuration
  Dir.mktmpdir("two-head-wu-unsafe-target-") do |directory|
    expect_config_rejected(directory) do |config, _fixture|
      config.fetch("targets").fetch("public-site")["ssh_target"] = "-oProxyCommand=agent-controlled"
    end
  end

  Dir.mktmpdir("two-head-wu-unsafe-root-") do |directory|
    expect_config_rejected(directory) do |config, _fixture|
      config.fetch("targets").fetch("public-site")["remote_root"] = "/srv/sites/../escape"
    end
  end

  Dir.mktmpdir("two-head-wu-unsafe-url-") do |directory|
    expect_config_rejected(directory) do |config, _fixture|
      config.fetch("targets").fetch("public-site")["verification_url"] = "http://127.0.0.1/private"
    end
  end

  Dir.mktmpdir("two-head-wu-unsafe-url-userinfo-") do |directory|
    expect_config_rejected(directory) do |config, _fixture|
      config.fetch("targets").fetch("public-site")["verification_url"] = "https://agent@verification.example.test/private"
    end
  end

  Dir.mktmpdir("two-head-wu-open-config-") do |directory|
    fixture = make_service_fixture(directory)
    File.chmod(0o644, fixture.fetch(:config_path))
    transport = SitePublisherTestSupport::FlakyFixtureTransport.new(Pathname.new(directory).join("no-upload"), failures: 0)
    service = build_service(fixture, transport: transport, verifier: SitePublisherTestSupport::FixtureReleaseVerifier.new(Pathname.new(directory).join("no-verify")))
    assert_rejected("service accepted a world-readable private configuration") { publish_from_archive(service, fixture) }
    assert(transport.attempts.zero?, "world-readable config reached transport")
  end
end

test_public_adapter_creates_only_a_frozen_release
test_fixed_socket_client_protocol
test_bounded_transport_timeout_is_retry_compatible
test_protected_service_behavior
test_service_rejects_untrusted_inputs
test_verified_publish_does_not_retry_when_audit_write_fails
test_service_rejects_unsafe_protected_configuration

puts "server-operations tests ok"
