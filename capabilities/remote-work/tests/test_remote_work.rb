# frozen_string_literal: true

require "fileutils"
require "json"
require "pathname"
require "rbconfig"
require "stringio"
require "tmpdir"
require "yaml"

require_relative "../lib/remote_work"
require_relative "../lib/member_runtime_release"
require_relative "../worker/app_server_bridge"
load File.expand_path("../installer/install-member-worker-runtime", __dir__)
load File.expand_path("../adapters/remote-work-deploy", __dir__)
load File.expand_path("../worker/ltw-worker", __dir__)

ROOT = Pathname.new(__dir__).join("../../..").expand_path.cleanpath

def assert(condition, message)
  raise message unless condition
end

release_key = OpenSSL::PKey::RSA.new(2048)
release_manifest = {
  "schema_version" => 2,
  "release_id" => "v0.5.0-0123456789ab",
  "version" => "0.5.0",
  "channel" => "stable",
  "sha256" => "a" * 64,
  "size" => 123,
  "generated_at" => "2026-08-23T00:00:00Z",
  "public_key_sha256" => Digest::SHA256.hexdigest(release_key.public_key.to_der)
}
release_manifest["signature_base64"] = RemoteWork::ReleaseSignature.sign(release_manifest, release_key.to_pem)
assert(RemoteWork::ReleaseSignature.verify!(release_manifest, release_key.public_key.to_pem), "signed release was rejected")
begin
  RemoteWork::ReleaseSignature.verify!(release_manifest.merge("size" => 124), release_key.public_key.to_pem)
  raise "tampered release manifest was accepted"
rescue RemoteWork::Error
  nil
end

inventory_manifest = {
  "schema_version" => 1,
  "inventory_version" => "fedcba9876543210",
  "generated_at" => "2026-08-23T00:00:00Z",
  "source_device" => "mac-mini",
  "entries" => [{
    "id" => "skill:paper-writing",
    "kind" => "skill",
    "name" => "paper-writing",
    "summary" => "safe descriptive metadata",
    "status" => "active",
    "air_mode" => "portable",
    "location" => "mac-mini",
    "category" => "academic-research"
  }],
  "public_key_sha256" => Digest::SHA256.hexdigest(release_key.public_key.to_der)
}
inventory_manifest["signature_base64"] = RemoteWork::CapabilityInventorySignature.sign(inventory_manifest, release_key.to_pem)
assert(
  RemoteWork::CapabilityInventorySignature.verify!(inventory_manifest, release_key.public_key.to_pem),
  "signed Mini capability inventory was rejected"
)
begin
  changed_inventory = inventory_manifest.merge(
    "entries" => inventory_manifest.fetch("entries").map { |item| item.merge("air_mode" => "remote-auto") }
  )
  RemoteWork::CapabilityInventorySignature.verify!(changed_inventory, release_key.public_key.to_pem)
  raise "tampered Mini capability inventory was accepted"
rescue RemoteWork::Error
  nil
end

capability_manifest = {
  "schema_version" => 1,
  "catalog_version" => "0123456789abcdef",
  "generated_at" => "2026-08-23T00:00:00Z",
  "capabilities" => [{
    "id" => "tool:codex-status",
    "name" => "Codex 额度状态",
    "kind" => "tool",
    "location" => "mac-mini",
    "exposure" => "callable",
    "status" => "active",
    "invocation_policy" => "auto",
    "side_effect" => "read-only",
    "queueable" => true,
    "runtime_requires" => ["codex-status"],
    "summary" => "safe"
  }],
  "public_key_sha256" => Digest::SHA256.hexdigest(release_key.public_key.to_der)
}
capability_manifest["signature_base64"] = RemoteWork::CapabilityCatalogSignature.sign(capability_manifest, release_key.to_pem)
assert(
  RemoteWork::CapabilityCatalogSignature.verify!(capability_manifest, release_key.public_key.to_pem),
  "signed capability catalog was rejected"
)
begin
  changed_catalog = capability_manifest.merge(
    "capabilities" => capability_manifest.fetch("capabilities").map { |item| item.merge("invocation_policy" => "confirm") }
  )
  RemoteWork::CapabilityCatalogSignature.verify!(changed_catalog, release_key.public_key.to_pem)
  raise "tampered capability catalog was accepted"
rescue RemoteWork::Error
  nil
end

module_manifest = {
  "schema_version" => 2,
  "generated_at" => "2026-08-23T00:00:00Z",
  "modules" => [{ "id" => "skill:remote-work", "classification" => "portable", "status" => "active" }],
  "public_key_sha256" => Digest::SHA256.hexdigest(release_key.public_key.to_der)
}
module_manifest["signature_base64"] = RemoteWork::ModuleSignature.sign(module_manifest, release_key.to_pem)
assert(RemoteWork::ModuleSignature.verify!(module_manifest, release_key.public_key.to_pem), "signed module manifest was rejected")
begin
  changed_modules = module_manifest.merge("modules" => [{ "id" => "skill:remote-work", "classification" => "portable", "status" => "revoked" }])
  RemoteWork::ModuleSignature.verify!(changed_modules, release_key.public_key.to_pem)
  raise "tampered module manifest was accepted"
rescue RemoteWork::Error
  nil
end

fake_server = <<~'RUBY'
  require "json"
  STDOUT.sync = true
  while (line = STDIN.gets)
    message = JSON.parse(line)
    case message["method"]
    when "initialize"
      puts JSON.generate("id" => message["id"], "result" => { "userAgent" => "fake", "platformFamily" => "unix", "platformOs" => "macos", "codexHome" => "/tmp/fake" })
    when "model/list"
      puts JSON.generate("id" => "server-approval", "method" => "item/commandExecution/requestApproval", "params" => { "itemId" => "i", "threadId" => "t", "turnId" => "u", "startedAtMs" => 1, "availableDecisions" => ["accept", "decline"] })
      approval = JSON.parse(STDIN.gets)
      exit 9 unless approval.dig("result", "decision") == "decline"
      puts JSON.generate("id" => message["id"], "result" => { "data" => [{ "id" => "fake-model" }] })
    end
    STDOUT.flush
  end
RUBY
handled_request = nil
RemoteWork::AppServerBridge.new(
  command: [RbConfig.ruby, "-e", fake_server],
  request_handler: proc do |method, _params|
    handled_request = method
    { "decision" => "decline" }
  end
).with_session do |session|
  response = session.request("model/list", {})
  assert(response.dig("data", 0, "id") == "fake-model", "app-server response was not routed")
end
assert(handled_request == "item/commandExecution/requestApproval", "app-server request was not routed")

quota_worker = LTWWorker.new([])
quota_limits = {
  "rateLimits" => {
    "limitId" => "codex",
    # Deliberately reverse the provider positions. The semantic mapping must
    # follow windowDurationMins, not a remembered primary/secondary label.
    "primary" => { "usedPercent" => 20, "windowDurationMins" => 10_080, "resetsAt" => 1_800_500_000 },
    "secondary" => { "usedPercent" => 50, "windowDurationMins" => 300, "resetsAt" => 1_800_000_000 }
  }
}
quota = quota_worker.send(
  :normalize_codex_quota,
  "owner-primary",
  { "email" => "owner@example.invalid", "planType" => "plus" },
  quota_limits
)
assert(quota.dig("five_hour", "window_duration_mins") == 300, "five-hour quota did not follow the 300-minute window")
assert(quota.dig("five_hour", "remaining_percent") == 50.0, "five-hour remaining quota drift")
assert(quota.dig("weekly", "window_duration_mins") == 10_080, "weekly quota did not follow the 10080-minute window")
assert(quota.dig("weekly", "remaining_percent") == 80.0, "weekly remaining quota drift")
assert(quota["primary"] == quota.dig("rate_limits", 0, "primary"), "legacy primary quota field was not preserved")

unknown_windows = quota_worker.send(
  :normalize_codex_quota,
  "owner-primary",
  { "email" => "owner@example.invalid", "planType" => "plus" },
  { "rateLimits" => {
    "primary" => { "usedPercent" => 10, "windowDurationMins" => 60 },
    "secondary" => { "usedPercent" => 20, "windowDurationMins" => 1_440 }
  } }
)
assert(unknown_windows["five_hour"].nil?, "an unknown primary duration was mislabeled as five-hour quota")
assert(unknown_windows["weekly"].nil?, "an unknown secondary duration was mislabeled as weekly quota")

# The renderer also accepts a v1 Worker payload that has no explicit
# five_hour/weekly keys, so a client update remains compatible during rollout.
legacy_quota_output = {
  "source_device" => "mac-mini-worker",
  "observed_at" => "2026-08-25T20:00:00Z",
  "accounts" => [{
    "identity" => "owner-primary",
    "status" => "ok",
    "account" => { "email" => "owner@example.invalid", "plan_type" => "plus" },
    "primary" => { "remaining_percent" => 50.0, "window_duration_mins" => 300, "resets_at" => 1_800_000_000 },
    "rate_limits" => [{
      "primary" => { "remaining_percent" => 50.0, "window_duration_mins" => 300, "resets_at" => 1_800_000_000 },
      "secondary" => { "remaining_percent" => 80.0, "window_duration_mins" => 10_080, "resets_at" => 1_800_500_000 }
    }]
  }]
}
rendered_quota = RemoteWork::CodexStatusFormatter.new(legacy_quota_output).render
assert(rendered_quota.include?("Codex 账户额度"), "quota output lost its organized heading")
assert(rendered_quota.include?("5 小时") && rendered_quota.include?("50%"), "quota output omitted the five-hour window")
assert(rendered_quota.include?("7 天") && rendered_quota.include?("80%"), "quota output omitted the weekly window")
assert(rendered_quota.include?("[█████░░░░░]"), "quota output omitted the visual remaining meter")
assert(!rendered_quota.include?("\t"), "quota output fell back to unorganized tab-separated rendering")

[
  RemoteWorkDeploy::INSPECT_SCRIPT,
  RemoteWorkDeploy::DEPLOY_SCRIPT,
  RemoteWorkDeploy::NGINX_SCRIPT
].each do |script|
  IO.popen(["sh", "-n"], "w") { |io| io.write(script) }
  assert($?.success?, "fixed remote deployment script has invalid shell syntax")
end
assert(RemoteWorkDeploy::NGINX_SCRIPT.include?("target_blocks"), "HTTPS route installer does not distinguish the TLS server block")
assert(RemoteWorkDeploy::NGINX_SCRIPT.include?("location /two-head-wu/v1/"), "HTTPS route installer lost the owner v1 route")
assert(RemoteWorkDeploy::NGINX_SCRIPT.include?("location /two-head-wu/v2/"), "HTTPS route installer does not publish the member v2 route")
assert(RemoteWorkDeploy::NGINX_SCRIPT.include?("/two-head-wu/v2/health"), "HTTPS route installer does not health-check the member v2 route")
assert(RemoteWorkDeploy::DEPLOY_SCRIPT.include?("systemctl restart two-head-wu-control-plane.service"), "control-plane deployment can leave the old process running")
assert(RemoteWorkDeploy::DEPLOY_SCRIPT.include?("service-version-health-failed"), "deployment does not verify the running control-plane version")
assert(RemoteWorkDeploy::DEPLOY_SCRIPT.include?("rollback_service_deployment"), "control-plane deployment has no failure rollback")
assert(RemoteWorkDeploy::DEPLOY_SCRIPT.include?("service-deploy.$build_id.XXXXXX"), "control-plane deployment has no versioned pre-mutation backup")
assert(RemoteWorkDeploy::DEPLOY_SCRIPT.include?("committed=1"), "control-plane deployment cannot distinguish a committed release")
assert(RemoteWorkDeploy::DEPLOY_SCRIPT.include?("two-head-wu-member-cleanup.timer"), "member ContentLease cleanup has no systemd timer")
assert(RemoteWorkDeploy::DEPLOY_SCRIPT.include?("OnUnitActiveSec=1h"), "member ContentLease cleanup interval drifted")
assert(RemoteWorkDeploy::DEPLOY_SCRIPT.include?("RandomizedDelaySec=5min"), "member ContentLease cleanup timer lost jitter")
assert(RemoteWorkDeploy::DEPLOY_SCRIPT.include?("SyslogIdentifier=two-head-wu-member-cleanup"), "member cleanup failures are not journal-visible")

Dir.mktmpdir("member-worker-token-output-") do |temporary|
  deploy = RemoteWorkDeploy.new(%w[--project two-head-wu --approve --device mac-mini-air-worker])
  deploy.instance_variable_set(:@root, Pathname.new(temporary))
  deploy.define_singleton_method(:authorized_catalogs!) { |_project| {} }
  deploy.define_singleton_method(:public_health!) { true }
  issuance = nil
  deploy.define_singleton_method(:issue_remote_token) do |device, role, ttl:|
    issuance = [device, role, ttl]
    "z" * 43
  end
  previous_stdout = $stdout
  output = StringIO.new
  begin
    $stdout = output
  status = deploy.send(:issue_air_worker_enrollment)
  ensure
    $stdout = previous_stdout
  end
  token_path = Pathname.new(output.string.strip)
  assert(status.zero?, "member worker enrollment issuance failed")
  assert(issuance == ["mac-mini-air-worker", "mac-mini-air-worker", 600], "Air worker enrollment role or TTL drifted")
  assert(token_path.read(encoding: "UTF-8").strip == "z" * 43, "member worker enrollment token was not written exactly")
  assert((token_path.stat.mode & 0o777) == 0o600, "member worker enrollment token permissions are not private")
  assert(!output.string.include?("z" * 43), "member worker enrollment token leaked to stdout")
end

Dir.mktmpdir("air-pairing-kit-output-") do |temporary|
  deploy = RemoteWorkDeploy.new(%w[--project two-head-wu --approve --identity owner-primary --role owner --platform macos])
  deploy.instance_variable_set(:@root, Pathname.new(temporary))
  deploy.define_singleton_method(:authorized_catalogs!) { |_project| {} }
  deploy.define_singleton_method(:public_air_health!) { true }
  calls = []
  deploy.define_singleton_method(:remote_control_plane_json) do |*arguments|
    calls << arguments
    if arguments.first == "ensure-air-user"
      {
        "created" => true,
        "user" => { "id" => "usr-owner-kit0001", "role" => "owner" },
        "codex_binding" => { "identity_alias" => "owner-primary" }
      }
    else
      { "created" => true, "grant" => { "id" => "grant-owner-kit0001" } }
    end
  end
  deploy.define_singleton_method(:remote_air_pairing_token) do |user_id, platform|
    raise "wrong Air pairing subject" unless user_id == "usr-owner-kit0001" && platform == "macos"
    "pair-" + ("z" * 43)
  end
  previous_stdout = $stdout
  output = StringIO.new
  begin
    $stdout = output
    status = deploy.send(:issue_air_pairing_kit)
  ensure
    $stdout = previous_stdout
  end
  kit = Pathname.new(output.string.strip)
  assert(status.zero? && kit.directory?, "Air pairing kit was not created")
  token = kit.join("pairing.token").read(encoding: "UTF-8").strip
  assert(token == "pair-" + ("z" * 43), "Air pairing kit token changed")
  assert((kit.stat.mode & 0o777) == 0o700, "Air pairing kit directory is not private")
  assert((kit.join("pairing.token").stat.mode & 0o777) == 0o600, "Air pairing token is not private")
  assert(!output.string.include?(token), "Air pairing token leaked to stdout")
  metadata = JSON.parse(kit.join("kit.json").read(encoding: "UTF-8"))
  assert(metadata["identity_alias"] == "owner-primary" && metadata["installer"] == "separate-common-signed-package",
         "Air pairing kit metadata is invalid")
  granted = calls.drop(1).map { |arguments| arguments[arguments.index("--capability") + 1] }.sort
  assert(granted == RemoteWorkDeploy::AIR_GRANT_PROFILES.fetch("owner").keys.sort,
         "owner Air pairing kit did not install the exact grant profile")
  instructions = kit.join("安装说明.txt").read(encoding: "UTF-8")
  assert(instructions.include?(RemoteWorkDeploy::AIR_ENDPOINT) && !instructions.include?(token),
         "Air pairing instructions leaked the token or lost the fixed endpoint")
end

begin
  invalid_kit = RemoteWorkDeploy.new(%w[--project two-head-wu --approve --identity owner-secondary --role member --platform windows])
  invalid_kit.send(:parse_air_pairing_kit_options!)
  raise "Air pairing kit accepted an owner alias as a member"
rescue RemoteWork::Error => error
  assert(error.message.include?("owner role"), "Air pairing kit rejected an owner alias ambiguously")
end

Dir.mktmpdir("remote-worker-runtime-") do |temporary|
  previous_home = ENV["HOME"]
  ENV["HOME"] = temporary
  begin
    deploy = RemoteWorkDeploy.new([])
    first = deploy.send(:install_worker_runtime)
    second = deploy.send(:install_worker_runtime)
    assert(first == second, "Mac mini worker runtime installation is not idempotent")
    assert(first.file? && first.executable?, "Mac mini worker runtime is not executable")
    assert(first.to_s.start_with?(File.join(temporary, ".local", "share", "two-head-wu")), "Mac mini worker runtime escaped the local user install root")
    assert(first.read(encoding: "UTF-8").include?("class LTWWorker"), "Mac mini worker runtime content verification failed")
    worker_release = first.join("../../../..").cleanpath
    skill_manifest_path = worker_release.join("skills/remote-task/manifest.json")
    assert(skill_manifest_path.file?, "Mac mini worker release has no remote-task Skill manifest")
    skill_manifest = JSON.parse(skill_manifest_path.read(encoding: "UTF-8"))
    bundled_skills = skill_manifest.fetch("skills").map { |item| item.fetch("skill_id") }
    expected_skills = YAML.safe_load(
      ROOT.join("capabilities/remote-work/policies/owner-only.yaml").read(encoding: "UTF-8"),
      permitted_classes: [], aliases: false
    ).dig("capability_inventory", "remote_task_skills")
    assert(bundled_skills == expected_skills, "Mac mini worker remote-task Skill bundle drift")
    assert(!bundled_skills.include?("agent-identity") && !bundled_skills.include?("remote-work-bootstrap"), "administrative Skill entered the remote-task bundle")
    skill_manifest.fetch("skills").each do |item|
      skill_root = worker_release.join("skills/remote-task", item.fetch("path"))
      assert(skill_root.join("SKILL.md").file?, "bundled remote-task Skill entrypoint is missing")
      assert((skill_root.join("SKILL.md").stat.mode & 0o222).zero?, "bundled remote-task Skill entrypoint is writable")
    end
  ensure
    ENV["HOME"] = previous_home
    FileUtils.chmod_R(0o700, temporary) if File.directory?(temporary)
  end
end

Dir.mktmpdir("remote-worker-owner-selector-") do |temporary|
  root = Pathname.new(temporary)
  adapter = root.join("identity-adapter")
  log = root.join("identity-arguments.json")
  adapter.write(<<~RUBY, encoding: "UTF-8")
    #!/usr/bin/env ruby
    require "json"
    File.write(ENV.fetch("IDENTITY_ARGUMENT_LOG"), JSON.generate(ARGV))
    puts JSON.generate("identity" => ENV.fetch("IDENTITY_RESULT", "owner-secondary"))
  RUBY
  File.chmod(0o755, adapter.to_s)
  worker = LTWWorker.new([])
  worker.define_singleton_method(:agent_identity_adapter) { adapter.to_s }
  previous_log = ENV["IDENTITY_ARGUMENT_LOG"]
  previous_result = ENV["IDENTITY_RESULT"]
  begin
    ENV["IDENTITY_ARGUMENT_LOG"] = log.to_s
    ENV["IDENTITY_RESULT"] = "owner-secondary"
    assert(worker.send(:select_remote_identity) == "owner-secondary", "worker did not accept the secondary owner identity")
    assert(
      JSON.parse(log.read(encoding: "UTF-8")) == %w[route-select --channel remote-work --session owner-queue --json],
      "worker bypassed the shared remote-work owner selector"
    )
    ENV["IDENTITY_RESULT"] = "classmate"
    begin
      worker.send(:select_remote_identity)
      raise "worker accepted a non-owner automatic identity"
    rescue RemoteWork::Error => error
      assert(error.message.include?("non-owner"), "worker rejected the non-owner identity for the wrong reason")
    end
  ensure
    ENV["IDENTITY_ARGUMENT_LOG"] = previous_log
    ENV["IDENTITY_RESULT"] = previous_result
  end
end

Dir.mktmpdir("remote-worker-member-selector-") do |temporary|
  root = Pathname.new(temporary)
  member_home = root.join("member-home")
  member_home.mkdir
  adapter = root.join("identity-adapter")
  log = root.join("identity-arguments.json")
  adapter.write(<<~RUBY, encoding: "UTF-8")
    #!/usr/bin/env ruby
    require "json"
    File.write(ENV.fetch("IDENTITY_ARGUMENT_LOG"), JSON.generate(ARGV))
    value = JSON.parse(ENV.fetch("IDENTITY_MEMBER_RESULT"))
    puts JSON.generate(value)
  RUBY
  File.chmod(0o755, adapter.to_s)
  worker = LTWWorker.new([])
  worker.define_singleton_method(:agent_identity_adapter) { adapter.to_s }
  job = {
    "user_id" => "usr-member-a000000",
    "user_role" => "member",
    "codex_binding_id" => "cdx-member-a000000",
    "identity_alias" => "member-a"
  }
  previous_log = ENV["IDENTITY_ARGUMENT_LOG"]
  previous_result = ENV["IDENTITY_MEMBER_RESULT"]
  begin
    ENV["IDENTITY_ARGUMENT_LOG"] = log.to_s
    ENV["IDENTITY_MEMBER_RESULT"] = JSON.generate({
      "result" => "member-home", "identity" => "member-a",
      "usage_scope" => "member-remote-work", "codex_home" => member_home.to_s
    })
    resolved = worker.send(:resolve_member_identity, job)
    assert(resolved.fetch("identity") == "member-a", "worker did not resolve the fixed member identity")
    assert(resolved.fetch("codex_home") == member_home.to_s, "worker changed the member Codex home")
    assert(
      JSON.parse(log.read(encoding: "UTF-8")) == %w[member-home --alias member-a --json],
      "worker bypassed the member-only identity resolver"
    )
    runtime_home = root.join("runtime-home")
    runtime_home.mkdir
    runtime_home.join("tmp").mkdir
    previous_canary = ENV["AWS_SECRET_ACCESS_KEY"]
    ENV["AWS_SECRET_ACCESS_KEY"] = "CANARY_DO_NOT_EXPORT_ENV"
    environment = worker.send(:member_codex_environment, member_home.to_s, runtime_home)
    assert(environment.fetch("CODEX_HOME") == member_home.to_s, "member app-server lost its isolated Codex home")
    assert(environment.fetch("HOME") == runtime_home.to_s, "member app-server inherited the owner's home directory")
    assert(environment.fetch("PATH") == "/usr/bin:/bin:/usr/sbin:/sbin", "member app-server inherited owner executables")
    assert(environment.fetch("AWS_SECRET_ACCESS_KEY").nil?, "member app-server inherited a secret-shaped environment variable")
    ENV["AWS_SECRET_ACCESS_KEY"] = previous_canary

    owner_job = {
      "user_id" => "usr-owner-a0000000",
      "user_role" => "owner",
      "codex_binding_id" => "cdx-owner-a0000000",
      "identity_alias" => "owner-primary"
    }
    ENV["IDENTITY_MEMBER_RESULT"] = JSON.generate({
      "result" => "member-home", "identity" => "owner-primary",
      "usage_scope" => "member-remote-work", "codex_home" => member_home.to_s
    })
    owner_resolved = worker.send(:resolve_member_identity, owner_job)
    assert(owner_resolved.fetch("identity") == "owner-primary" && owner_resolved.fetch("user_role") == "owner",
           "registered owner Air could not use its fixed worker identity")

    [
      job.merge("identity_alias" => "owner-primary"),
      job.merge("identity_alias" => "member-b"),
      job.reject { |key, _value| key == "identity_alias" },
      job.reject { |key, _value| key == "user_role" }
    ].each do |invalid_job|
      begin
        worker.send(:resolve_member_identity, invalid_job)
        raise "worker accepted an invalid or mismatched member identity"
      rescue RemoteWork::Error => error
        assert(error.message.start_with?("identity_required:"), "member identity failure did not return identity_required")
      end
    end
    ENV["IDENTITY_MEMBER_RESULT"] = JSON.generate({
      "result" => "member-home", "identity" => "member-a",
      "usage_scope" => "member-remote-work", "codex_home" => member_home.to_s
    })

    posts = []
    fake_http = Object.new
    fake_http.define_singleton_method(:post) do |path, payload|
      posts << [path, payload]
      { "job" => { "state" => path.end_with?("/result") ? "succeeded" : "running" } }
    end
    worker.define_singleton_method(:http) { fake_http }
    executable_job = job.merge(
      "id" => "job-member-a000000",
      "execution_lease_id" => "work-aaaaaaaaaaaaaaaaaaaaaaaa",
      "instruction" => "test isolated member execution",
      "kind" => "codex",
      "capability_envelope" => {
        "schema_version" => 2,
        "capabilities" => ["codex:project-task"],
        "egress_profile" => "none",
        "secret_access" => "none",
        "result_mode" => "review-only"
      },
      "attempt" => 1
    )
    worker.send(:execute_member_job, executable_job, "test")
    assert(posts.any? { |path, payload| path.end_with?("/state") && payload["state"] == "running" }, "member job did not enter running")
    result_post = posts.find { |path, _payload| path.end_with?("/result") }
    assert(result_post, "member job did not upload a result package")
    assert(result_post.last["execution_lease_id"] == executable_job["execution_lease_id"], "member result lost its execution lease")

    posts.clear
    begin
      worker.send(:execute_member_job, executable_job.reject { |key, _value| key == "identity_alias" }, "test")
      raise "member job without an identity unexpectedly executed"
    rescue RemoteWork::Error => error
      assert(error.message.start_with?("identity_required:"), "missing member identity returned the wrong error")
    end
    failed_post = posts.find { |path, payload| path.end_with?("/state") && payload["state"] == "failed" }
    assert(failed_post && failed_post.last["failure_code"] == "identity_required", "identity failure was not reported deterministically")

    posts.clear
    member_capability_job = {
      "id" => "job-member-cap0000",
      "user_id" => "usr-member-a000000",
      "user_role" => "member",
      "codex_binding_id" => "cdx-member-a000000",
      "identity_alias" => "member-a",
      "execution_lease_id" => "work-bbbbbbbbbbbbbbbbbbbbbbbb",
      "instruction" => "search the research library",
      "kind" => "capability",
      "capability_id" => "research-library:search",
      "capability_input" => { "query" => "integration" },
      "capability_envelope" => {
        "schema_version" => 2,
        "capabilities" => ["research-library:search"],
        "egress_profile" => "registered-only",
        "secret_access" => "none",
        "result_mode" => "review-only"
      },
      "attempt" => 1
    }
    worker.send(:execute_member_job, member_capability_job, "test")
    assert(posts.any? { |path, _payload| path.end_with?("/result") }, "member read-only capability did not upload a result")
    provider = Object.new
    provider.define_singleton_method(:research_library_search) do |input|
      {
        "schema" => "two-head-wu.research-library.search.v1",
        "source_device" => "mac-mini-worker",
        "observed_at" => Time.now.utc.iso8601,
        "provider" => "research-library.search.v1",
        "partial" => false,
        "query" => input.fetch("query"),
        "results" => []
      }
    end
    provider.define_singleton_method(:research_library_get) do |_input|
      {
        "schema" => "two-head-wu.research-library.get.v1",
        "source_device" => "mac-mini-worker",
        "observed_at" => Time.now.utc.iso8601,
        "document" => {
          "work_id" => "00000000-0000-4000-8000-000000000001",
          "version_id" => "00000000-0000-4000-8000-000000000002",
          "sha256" => "a" * 64,
          "canonical_title" => "Member-safe metadata",
          "export_available" => true,
          "citation_authority" => "original"
        }
      }
    end
    worker.instance_variable_set(:@owner_capabilities, provider)
    posts.clear
    worker.send(:execute_member_job, member_capability_job, "codex")
    assert(posts.any? { |path, _payload| path.end_with?("/result") }, "member provider result was not returned")

    notebook_job = member_capability_job.merge(
      "id" => "job-owner-notebook0001",
      "user_id" => "usr-owner-air000001",
      "codex_binding_id" => "cdx-owner-air000001",
      "identity_alias" => "example-owner-air",
      "user_role" => "owner",
      "execution_lease_id" => "work-cccccccccccccccccccccccc",
      "instruction" => "invoke exact owner notebook",
      "capability_id" => "memory:notebook",
      "capability_input" => { "action" => "recall", "query" => "Air" },
      "capability_envelope" => member_capability_job.fetch("capability_envelope").merge(
        "capabilities" => ["memory:notebook"]
      )
    )
    worker.define_singleton_method(:run_protected_owner_notebook) do |_input|
      {
        "schema" => "two-head-wu.personal-memory.owner-air.v1",
        "action" => "recall",
        "observed_at" => Time.now.utc.iso8601,
        "result" => { "query" => "Air", "results" => [] }
      }
    end
    posts.clear
    worker.send(:execute_member_job, notebook_job, "codex")
    assert(posts.any? { |path, _payload| path.end_with?("/result") }, "owner notebook result was not returned")
    posts.clear
    begin
      worker.send(:execute_member_job, notebook_job.merge("user_role" => "member"), "codex")
      raise "ordinary Air user reached the protected owner notebook"
    rescue RemoteWork::Error => error
      assert(error.message.include?("registered owner Air"), "ordinary Air notebook denial returned the wrong error")
    end

    frozen = worker.send(:freeze_member_envelope!, executable_job)
    assert(frozen.fetch("sha256").match?(/\A[a-f0-9]{64}\z/), "member envelope was not digest frozen")
    begin
      frozen.fetch("value").fetch("capabilities") << "memory:personal"
      raise "frozen member envelope remained mutable"
    rescue FrozenError
      nil
    end
    [
      executable_job.merge("capability_envelope" => executable_job.fetch("capability_envelope").merge("secret_access" => "owner")),
      executable_job.merge("capability_envelope" => executable_job.fetch("capability_envelope").merge("unexpected" => true)),
      executable_job.merge("capability_envelope" => executable_job.fetch("capability_envelope").merge("capabilities" => ["memory:personal"]))
    ].each do |tampered|
      begin
        worker.send(:freeze_member_envelope!, tampered)
        raise "worker accepted a tampered member capability envelope"
      rescue RemoteWork::Error
        nil
      end
    end

    worker.define_singleton_method(:member_codex_binary) { "/usr/bin/true" }
    command = worker.send(:member_codex_command, root.join("workspace"), root.join("final.md"))
    %w[--ignore-user-config --ignore-rules --ephemeral].each do |flag|
      assert(command.include?(flag), "member Codex command did not include #{flag}")
    end
    assert(command.include?("sandbox_workspace_write.network_access=false"), "member Codex command did not disable network")
    assert(command.include?("project_doc_max_bytes=0"), "member Codex command still auto-loads project AGENTS.md")
    LTWWorker::MEMBER_DISABLED_FEATURES.each do |feature|
      assert(command.each_cons(2).any? { |pair| pair == ["--disable", feature] }, "member Codex command enabled #{feature}")
    end
    app_command = worker.send(:member_app_server_command)
    assert(app_command.include?("mcp_servers={}"), "member app-server did not clear MCP configuration")
    assert(app_command.include?("sandbox_workspace_write.network_access=false"), "member app-server did not disable network")
    thread_params = worker.send(:member_thread_start_params, root.join("workspace"), frozen)
    assert(thread_params.fetch("dynamicTools") == [], "member thread registered dynamic tools")
    assert(thread_params.fetch("selectedCapabilityRoots") == [], "member thread inherited capability roots")
    assert(thread_params.dig("config", "mcp_servers") == {}, "member thread inherited MCP servers")
    assert(thread_params.dig("config", "sandbox_workspace_write", "network_access") == false, "member thread enabled network")
    assert(thread_params.dig("config", "project_doc_max_bytes") == 0, "member thread still auto-loads project AGENTS.md")
    assert(thread_params.fetch("runtimeWorkspaceRoots") == [root.join("workspace").to_s], "member thread widened writable roots")

    injection_fixture = JSON.parse(
      File.read(File.join(__dir__, "fixtures", "prompt-injection-v2.json"), encoding: "UTF-8")
    )
    sinks = injection_fixture.fetch("cases").flat_map { |item| item.fetch("attempted_sinks") }.uniq.sort
    assert(sinks == %w[direct-write egress privilege secret], "prompt-injection fixture lost a required sink")
    injection_sources = injection_fixture.fetch("cases").map { |item| item.fetch("source") }
    %w[AGENTS.md README.md comment PDF Unicode web MCP].each do |source_kind|
      assert(injection_sources.any? { |source| source.include?(source_kind) }, "prompt-injection fixture lost #{source_kind}")
    end
    sink_guards = {
      "secret" => frozen.dig("value", "secret_access") == "none",
      "egress" => thread_params.dig("config", "sandbox_workspace_write", "network_access") == false &&
                  thread_params.dig("config", "mcp_servers") == {},
      "privilege" => thread_params.fetch("dynamicTools").empty? &&
                     thread_params.fetch("selectedCapabilityRoots").empty?,
      "direct-write" => thread_params.fetch("runtimeWorkspaceRoots") == [root.join("workspace").to_s] &&
                        frozen.dig("value", "result_mode") == "review-only"
    }
    injection_fixture.fetch("cases").each do |item|
      injected = executable_job.merge("instruction" => item.fetch("payload"))
      injection_envelope = worker.send(:freeze_member_envelope!, injected)
      prompt = worker.send(:member_worker_prompt, injected, injection_envelope)
      assert(prompt.include?(item.fetch("payload")), "untrusted content was not kept in the task data position")
      assert(prompt.include?(injection_envelope.fetch("sha256")), "untrusted content detached the frozen envelope digest")
      item.fetch("attempted_sinks").each do |sink|
        assert(sink_guards.fetch(sink), "prompt-injection case #{item.fetch('id')} reached the #{sink} sink")
      end
      begin
        worker.send(:reject_member_result_bytes!, item.fetch("simulated_result"), item.fetch("id"))
        raise "prompt-injection result reached an export sink"
      rescue RemoteWork::Error => error
        assert(error.message.include?("DLP"), "prompt-injection sink failed ambiguously")
      end
    end

    cancellation_job_id = "job-member-cancel0001"
    worker.instance_variable_get(:@job_flags_mutex).synchronize do
      worker.instance_variable_get(:@job_flags)[cancellation_job_id] = { cancelled: false, stop: false }
    end
    cancellation_pid = nil
    begin
      Open3.popen3("/bin/sh", "-c", "trap '' TERM; sleep 30", pgroup: true) do |stdin, stdout, stderr, wait|
        cancellation_pid = wait.pid
        stdin.close
        stdout.close
        stderr.close
        monitor = worker.send(:start_member_process_cancellation, cancellation_job_id, wait)
        worker.send(:mark_job_cancelled, cancellation_job_id)
        assert(wait.join(5), "cancelled member process group did not stop within the bounded grace period")
        monitor.join(1)
        assert(!monitor.alive?, "member cancellation monitor remained alive after process termination")
      end
      begin
        Process.kill(0, -cancellation_pid)
        raise "cancelled member process group left a residual process"
      rescue Errno::ESRCH
        nil
      end
    ensure
      begin
        Process.kill("KILL", -cancellation_pid) if cancellation_pid
      rescue Errno::ESRCH
        nil
      end
      worker.instance_variable_get(:@job_flags_mutex).synchronize do
        worker.instance_variable_get(:@job_flags).delete(cancellation_job_id)
      end
    end

    dlp_dir = root.join("dlp-result")
    dlp_dir.mkdir
    dlp_dir.join("final.md").write("CANARY_DO_NOT_EXPORT_INJECTION", encoding: "UTF-8")
    begin
      worker.send(:validate_member_result_tree!, dlp_dir)
      raise "member result DLP exported a secret canary"
    rescue RemoteWork::Error => error
      assert(error.message.include?("DLP"), "member result DLP returned an ambiguous failure")
    end
    credential_workspace = root.join("credential-workspace")
    credential_workspace.mkdir
    worker.send(:initialize_baseline_git, credential_workspace)
    credential_workspace.join(".env").write("SERVICE_PASSWORD=fixture-value\n", encoding: "UTF-8")
    begin
      worker.send(:validate_member_workspace_outputs!, credential_workspace)
      raise "credential-shaped member file reached the patch sink"
    rescue RemoteWork::Error => error
      assert(error.message.include?("credential-shaped"), "credential-shaped output failed ambiguously")
    end
    posts.clear
    member_get_job = member_capability_job.merge(
      "id" => "job-member-get0000",
      "execution_lease_id" => "work-cccccccccccccccccccccccc",
      "capability_id" => "research-library:get",
      "capability_input" => { "work_id" => "00000000-0000-4000-8000-000000000001" },
      "capability_envelope" => member_capability_job.fetch("capability_envelope").merge(
        "capabilities" => ["research-library:get"]
      )
    )
    worker.send(:execute_member_job, member_get_job, "codex")
    assert(posts.any? { |path, _payload| path.end_with?("/result") }, "member research get result was not returned")
    posts.clear
    member_status_job = member_capability_job.merge(
      "id" => "job-member-status00",
      "execution_lease_id" => "work-dddddddddddddddddddddddd",
      "capability_id" => "tool:codex-status",
      "capability_input" => {},
      "capability_envelope" => member_capability_job.fetch("capability_envelope").merge(
        "capabilities" => ["tool:codex-status"]
      )
    )
    worker.send(:execute_member_job, member_status_job, "test")
    status_result = posts.find { |path, _payload| path.end_with?("/result") }
    assert(status_result, "member Codex status did not return a result")
    Dir.mktmpdir("member-status-result-") do |result_temporary|
      archive = Pathname.new(result_temporary).join("result.tar.gz")
      extracted = Pathname.new(result_temporary).join("extracted")
      archive.binwrite(Base64.strict_decode64(status_result.last.fetch("result_base64")))
      RemoteWork::Archive.unpack(archive, extracted)
      status_output = JSON.parse(extracted.join("output.json").read(encoding: "UTF-8"))
      accounts = status_output.fetch("accounts")
      assert(accounts.length == 1 && accounts.first.fetch("identity") == "member-a", "member status enumerated another identity")
      allowed = %w[identity status account primary five_hour weekly rate_limits error]
      assert((accounts.first.keys - allowed).empty?, "member status returned a non-allowlisted account field")
      assert(accounts.first.fetch("account").keys.sort == %w[email plan_type], "member status account projection drifted")
      assert(!JSON.generate(status_output).include?("owner-primary"), "member status leaked the owner identity")
    end
    begin
      worker.send(
        :validate_member_capability_output!,
        { "schema" => "fixture.v1", "database_path" => "/home/example/private.sqlite3" },
        "fixture.v1"
      )
      raise "member capability output accepted a private database path"
    rescue RemoteWork::Error => error
      assert(error.message.include?("private"), "member output DLP failed for the wrong reason")
    end
  ensure
    ENV["IDENTITY_ARGUMENT_LOG"] = previous_log
    ENV["IDENTITY_MEMBER_RESULT"] = previous_result
  end
end

Dir.mktmpdir("remote-worker-member-content-") do |temporary|
  root = Pathname.new(temporary)
  source = root.join("source")
  workspace = root.join("workspace")
  task_root = root.join("task")
  [source, workspace, task_root].each { |path| path.mkdir }
  source.join("project.txt").write("project capsule\n", encoding: "UTF-8")
  archive = root.join("project.tar.gz")
  RemoteWork::Archive.pack_directory(source, archive)
  project_bytes = archive.binread
  input_bytes = "member input\n"
  job = {
    "id" => "job-member-content000",
    "user_id" => "usr-member-content000",
    "execution_lease_id" => "work-aaaaaaaaaaaaaaaaaaaaaaaa",
    "content_lease_ids" => %w[content-project0000 content-input000000]
  }
  now = "2026-09-02T00:00:00Z"
  expires = "2026-09-16T00:00:00Z"
  records = {
    "content-project0000" => ["project-capsule", "project.tar.gz", "application/gzip", project_bytes],
    "content-input000000" => ["input-artifact", "notes.txt", "text/plain", input_bytes]
  }.to_h do |id, (kind, filename, media_type, bytes)|
    digest = Digest::SHA256.hexdigest(bytes)
    lease = {
      "schema_version" => 2, "id" => id, "user_id" => job["user_id"], "job_id" => job["id"],
      "kind" => kind, "state" => "available", "sha256" => digest, "size" => bytes.bytesize,
      "receipt_required" => false, "created_at" => now, "expires_at" => expires
    }
    content = {
      "schema_version" => 2, "id" => id, "user_id" => job["user_id"], "job_id" => job["id"],
      "filename" => filename, "media_type" => media_type, "sha256" => digest, "size" => bytes.bytesize
    }
    [id, { "metadata" => { "content_lease" => lease, "content" => content }, "bytes" => bytes }]
  end
  fake_http = Object.new
  fake_http.define_singleton_method(:get) do |path|
    id = path[%r{/content/(content-[a-z0-9-]+)/metadata}, 1]
    records.fetch(id).fetch("metadata")
  end
  fake_http.define_singleton_method(:get_bytes) do |path|
    id = path[%r{/content/(content-[a-z0-9-]+)\?}, 1]
    records.fetch(id).fetch("bytes")
  end
  worker = LTWWorker.new([])
  worker.define_singleton_method(:http) { fake_http }
  worker.send(:materialize_member_content, job, workspace, task_root)
  assert(workspace.join("project.txt").read(encoding: "UTF-8") == "project capsule\n", "member project capsule was not materialized")
  assert(
    workspace.join("inputs/content-input000000-notes.txt").read(encoding: "UTF-8") == input_bytes,
    "member input artifact was not materialized into the task input directory"
  )
end

Dir.mktmpdir("remote-worker-member-runtime-") do |temporary|
  root = Pathname.new(temporary).realpath
  runtime_root = root.join("runtime")
  codex_root = runtime_root.join("codex-homes")
  worker_home = runtime_root.join("worker-home")
  temporary_root = runtime_root.join("tmp")
  member_home = codex_root.join("member-a")
  [runtime_root, codex_root, worker_home, temporary_root, member_home].each do |path|
    FileUtils.mkdir_p(path.to_s, mode: 0o700)
    File.chmod(0o700, path.to_s)
  end
  username = Etc.getpwuid(Process.euid).name
  environment = {
    "WU_MEMBER_RUNTIME_USER" => username,
    "WU_MEMBER_RUNTIME_UID" => Process.euid.to_s,
    "WU_MEMBER_OWNER_UID" => (Process.euid + 1).to_s,
    "WU_MEMBER_RUNTIME_ROOT" => runtime_root.to_s,
    "WU_MEMBER_RELEASE_ROOT" => "/usr",
    "WU_MEMBER_CODEX_ROOT" => codex_root.to_s,
    "WU_MEMBER_PRIVATE_CANARIES" => "/owner/private/canary-a#{File::PATH_SEPARATOR}/owner/private/canary-b",
    "WU_REMOTE_WORKER_HOME" => worker_home.to_s,
    "WU_REMOTE_CODEX_BIN" => "/usr/bin/true"
  }
  guard = RemoteWork::MemberRuntimeGuard.new(
    environment: environment,
    username: username,
    canary_probe: ->(_path) { false },
    source_root: "/usr"
  )
  runtime = guard.verify!
  assert(runtime.fetch("temporary_root") == temporary_root.realpath, "member runtime did not pin its temporary root")
  assert(
    guard.verify_member_codex_home!(member_home, runtime) == member_home.realpath,
    "member runtime rejected a private identity home inside its Codex root"
  )

  sandbox_workspace = root.join("sandbox-workspace")
  sandbox_runtime = runtime_root.join("sandbox-runtime")
  [sandbox_workspace, sandbox_runtime].each { |path| path.mkdir(0o700) }
  allowed_file = sandbox_workspace.join("allowed.txt")
  forbidden_file = root.join("owner-canary.txt")
  allowed_file.write("workspace-visible\n", encoding: "UTF-8")
  forbidden_file.write("owner-private\n", encoding: "UTF-8")
  sandbox_command = RemoteWork::MemberSandbox.new.command(
    [
      "/bin/sh", "-c",
      'cat "$1"; if cat "$2" >/dev/null 2>&1; then exit 43; fi',
      "member-sandbox-test", allowed_file.to_s, forbidden_file.to_s
    ],
    workspace: sandbox_workspace,
    runtime_home: sandbox_runtime,
    codex_home: member_home
  )
  sandbox_stdout, sandbox_stderr, sandbox_status = Open3.capture3(*sandbox_command)
  assert(sandbox_status.success?, "member Seatbelt profile failed its live boundary probe: #{sandbox_stderr}")
  assert(sandbox_stdout == "workspace-visible\n", "member Seatbelt profile could not read its workspace")
  assert(!sandbox_stdout.include?("owner-private"), "member Seatbelt profile read an outside canary")

  begin
    RemoteWork::MemberRuntimeGuard.new(
      environment: environment.merge("WU_MEMBER_OWNER_UID" => Process.euid.to_s),
      username: username,
      canary_probe: ->(_path) { false },
      source_root: "/usr"
    ).verify!
    raise "member runtime accepted the owner uid"
  rescue RemoteWork::Error => error
    assert(error.message.include?("non-owner"), "owner uid was rejected for the wrong reason")
  end

  begin
    RemoteWork::MemberRuntimeGuard.new(
      environment: environment,
      username: username,
      canary_probe: ->(_path) { true },
      source_root: "/usr"
    ).verify!
    raise "member runtime accepted a readable owner canary"
  rescue RemoteWork::Error => error
    assert(error.message.include?("can read"), "readable owner canary was rejected for the wrong reason")
  end

  outside_home = root.join("outside-member-home")
  outside_home.mkdir(0o700)
  begin
    guard.verify_member_codex_home!(outside_home, runtime)
    raise "member runtime accepted a Codex home outside the registered root"
  rescue RemoteWork::Error => error
    assert(error.message.include?("escaped"), "escaped member Codex home was rejected for the wrong reason")
  end
end

Dir.mktmpdir("remote-owner-capabilities-") do |temporary|
  identity_adapter = Pathname.new(temporary).join("identity-adapter")
  identity_adapter.write(<<~RUBY, encoding: "UTF-8")
    #!/usr/bin/env ruby
    require "json"
    puts JSON.generate({
      "identities" => [{
        "id" => "owner-primary", "state_kind" => "default", "selection_mode" => "project-auto",
        "configured" => true, "shared_skills" => "managed-by-default", "conversation_pool" => "main"
      }],
      "project_bindings" => { "two-head-wu" => "owner-primary" }
    })
  RUBY
  File.chmod(0o755, identity_adapter.to_s)
  adapters = RemoteWork::OwnerCapabilityAdapters.new(
    runtime_root: ROOT,
    source_root: ROOT,
    pipeline_root: ROOT,
    identity_adapter: identity_adapter,
    version: RemoteWork::VERSION
  )
  identity = adapters.identity_catalog
  assert(identity.fetch("schema") == "two-head-wu.identity-catalog.v1", "identity adapter schema drift")
  assert(identity.fetch("identities").first.keys.none? { |key| key.match?(/home|auth|token/i) }, "identity adapter leaked protected fields")

  resources = adapters.resource_catalog({})
  assert(resources.fetch("entries").length == 8, "resource adapter lost registered resources")
  serialized_resources = JSON.generate(resources)
  assert(!serialized_resources.match?(/private_ref|secret_ref|ssh|credential|password|token/i), "resource adapter leaked private metadata")
  selected_resource = adapters.resource_catalog({ "id" => "edge-server" })
  assert(selected_resource.fetch("entries").map { |item| item.fetch("id") } == ["edge-server"], "resource filter drift")

  search_arguments = adapters.send(:openai_docs_arguments, "search", { "action" => "search", "query" => "Codex resume", "limit" => 1 })
  assert(search_arguments == { "query" => "Codex resume", "limit" => 1 }, "OpenAI Docs adapter input mapping drift")
  begin
    adapters.send(:openai_docs_arguments, "fetch", { "action" => "fetch", "url" => "http://127.0.0.1/private" })
    raise "OpenAI Docs adapter accepted an arbitrary endpoint"
  rescue RemoteWork::Error
    nil
  end
  begin
    adapters.run_workflow(
      { "capability_id" => "workflow:refresh-documentation", "command" => ["core/bin/wu-docs", "update"], "requires_owner_confirmation" => true },
      {}, owner_confirmed: false
    )
    raise "mutating workflow adapter ran without owner confirmation"
  rescue RemoteWork::Error
    nil
  end

  library_root = Pathname.new(temporary).join("research-library")
  fixture = Pathname.new(temporary).join("fixture.md")
  metadata = Pathname.new(temporary).join("metadata.json")
  fixture.write("A complete remote research fixture about archival interfaces.\n", encoding: "UTF-8")
  metadata.write(JSON.generate({
    "title" => "Archival Interfaces",
    "kind" => "article",
    "publication_date" => "2026-08-01",
    "version_kind" => "published",
    "creators" => ["Ada Example"],
    "language" => "en"
  }), encoding: "UTF-8")
  library_adapter = ROOT.join("capabilities/research-library/adapters/research-library").to_s
  environment = { "TWO_HEAD_WU_RESEARCH_LIBRARY_ROOT" => library_root.to_s, "PYTHONDONTWRITEBYTECODE" => "1" }
  _stdout, stderr, status = Open3.capture3(environment, library_adapter, "--data-root", library_root.to_s, "initialize", "--json")
  assert(status.success?, "research fixture initialization failed: #{stderr}")
  binding = Pathname.new(temporary).join("research-library-binding.json")
  binding.write(JSON.generate({
    "schema_version" => 1,
    "resource_id" => "private-data-service",
    "data_root" => library_root.to_s
  }), encoding: "UTF-8")
  stdout, stderr, status = Open3.capture3(
    environment, library_adapter, "ingest-file", "--path", fixture.to_s,
    "--metadata", metadata.to_s, "--confirmed-relevant", "--json"
  )
  assert(status.success?, "research fixture ingestion failed: #{stderr}")
  work_id = JSON.parse(stdout).dig("data", "work_id")
  previous_root = ENV["TWO_HEAD_WU_RESEARCH_LIBRARY_ROOT"]
  previous_binding = ENV["WU_RESEARCH_LIBRARY_BINDING_FILE"]
  begin
    ENV["TWO_HEAD_WU_RESEARCH_LIBRARY_ROOT"] = library_root.to_s
    ENV["WU_RESEARCH_LIBRARY_BINDING_FILE"] = binding.to_s
    search = adapters.research_library_search({ "query" => "archival interfaces", "limit" => 5 })
    selected = search.fetch("results").first
    assert(selected.fetch("work_id") == work_id, "remote research search lost the provider result")
    release_output = Pathname.new(temporary).join("member-release-output")
    member_release = RemoteWork::MemberRuntimeRelease.new(source_root: ROOT).build(output_root: release_output)
    release_adapters = RemoteWork::OwnerCapabilityAdapters.new(
      runtime_root: member_release, source_root: member_release, pipeline_root: member_release,
      identity_adapter: member_release.join("capabilities/agent-identity/adapters/agent-identity"),
      version: RemoteWork::VERSION
    )
    isolated_search = release_adapters.research_library_search({ "query" => "archival interfaces", "limit" => 5 })
    assert(isolated_search.fetch("results").first.fetch("work_id") == work_id,
           "member release could not query the explicitly bound read-only research provider")

    member_index = Pathname.new(temporary).join("member-index")
    FileUtils.mkdir_p(member_index.join("state"))
    member_database = member_index.join("state/library.sqlite3")
    escaped_database = member_database.to_s.gsub("'", "''")
    _backup_stdout, backup_stderr, backup_status = Open3.capture3(
      "/usr/bin/sqlite3", library_root.join("state/library.sqlite3").to_s,
      ".backup '#{escaped_database}'"
    )
    assert(backup_status.success?, "member research snapshot backup failed: #{backup_stderr}")
    sanitized_stdout, sanitized_stderr, sanitized_status = Open3.capture3(
      "/usr/bin/sqlite3", member_database.to_s, MemberWorkerInstaller::RESEARCH_SANITIZE_SQL
    )
    assert(sanitized_status.success? && sanitized_stdout.lines.map(&:strip).include?("ok"),
           "member research snapshot sanitization failed: #{sanitized_stderr}")
    marker = JSON.parse(library_root.join(".research-library-root.json").read(encoding: "UTF-8"))
    marker["member_index_snapshot"] = true
    marker["database_sha256"] = Digest::SHA256.file(member_database.to_s).hexdigest
    member_index.join(".research-library-root.json").write(JSON.generate(marker), encoding: "UTF-8")
    ENV["TWO_HEAD_WU_RESEARCH_LIBRARY_ROOT"] = member_index.to_s
    snapshot_search = release_adapters.research_library_search({ "query" => "archival interfaces", "limit" => 5 })
    assert(snapshot_search.fetch("results").first.fetch("work_id") == work_id,
           "member research index could not search its sanitized snapshot")
    snapshot_document = release_adapters.research_library_get({ "work_id" => work_id })
    assert(snapshot_document.fetch("document").fetch("work_id") == work_id,
           "member research index could not return document metadata without originals")
    snapshot_rows, _snapshot_error, snapshot_status = Open3.capture3(
      "/usr/bin/sqlite3", member_database.to_s,
      "SELECT count(*) FROM sources; SELECT count(*) FROM artifacts WHERE relative_path NOT LIKE 'member-index/%';"
    )
    assert(snapshot_status.success? && snapshot_rows.lines.map(&:strip) == %w[0 0],
           "member research index retained private storage references")
    ENV["TWO_HEAD_WU_RESEARCH_LIBRARY_ROOT"] = library_root.to_s
    assert(!member_release.join("core/bin/wu").exist?, "member release copied the owner control-plane entrypoint")
    assert(member_release.join("capabilities/remote-work/worker/member_runtime_guard.rb").file?,
           "member release omitted its runtime guard")
    assert(member_release.join("capabilities/remote-work/worker/member_sandbox.rb").file?,
           "member release omitted its Seatbelt wrapper")
    assert(member_release.join("capabilities/remote-work/worker/member-research-library").executable?,
           "member release omitted its read-only research index provider")
    assert(member_release.join("capabilities/remote-work/adapters/remote-work").executable?,
           "member release omitted its one-time enrollment client")
    member_manifest = JSON.parse(member_release.join("MEMBER_RUNTIME_MANIFEST.json").read(encoding: "UTF-8"))
    member_skill_ids = member_manifest.fetch("skills").map { |item| item.fetch("skill_id") }
    assert(!member_skill_ids.include?("two-head-wu") && !member_skill_ids.include?("agent-identity"),
           "member release bundled an administrative Skill")
    assert(!JSON.generate(member_manifest).match?(/auth\.json|device\.secret|resource-bindings|\/Users\//),
           "member release manifest contains owner state or credential paths")
    newer_fixture = Pathname.new(temporary).join("fixture-newer.md")
    newer_metadata = Pathname.new(temporary).join("metadata-newer.json")
    newer_fixture.write("A newer complete version that must not replace an exact remote selection.\n", encoding: "UTF-8")
    newer_metadata.write(JSON.generate({
      "title" => "Archival Interfaces", "kind" => "article", "publication_date" => "2026-08-20",
      "version_kind" => "published", "creators" => ["Ada Example"], "language" => "en"
    }), encoding: "UTF-8")
    _new_stdout, new_stderr, new_status = Open3.capture3(
      environment, library_adapter, "ingest-file", "--path", newer_fixture.to_s,
      "--metadata", newer_metadata.to_s, "--confirmed-relevant", "--json"
    )
    assert(new_status.success?, "newer research version ingestion failed: #{new_stderr}")
    document = adapters.research_library_get({ "work_id" => work_id })
    assert(!JSON.generate(document).include?(library_root.to_s), "remote research get leaked the data root")
    assert(!document.fetch("document").key?("artifact_path"), "remote research get leaked an artifact path")
    exported = adapters.research_library_export({
      "artifact_id" => selected.fetch("artifact_id"), "expected_sha256" => selected.fetch("sha256")
    })
    assert(exported.is_a?(RemoteWork::OwnerCapabilityAdapters::ArtifactExport), "research export did not select one artifact")
    assert(exported.path.binread == fixture.binread, "research export changed original bytes")
    assert(exported.path.binread != newer_fixture.binread, "research export silently followed latest")
    assert(!JSON.generate(exported.payload).include?(library_root.to_s), "research export payload leaked the data root")

    begin
      adapters.research_library_get({ "work_id" => work_id, "path" => "/" })
      raise "research get accepted an arbitrary path"
    rescue RemoteWork::Error => error
      assert(error.message.include?("unknown fields"), "arbitrary research path was rejected ambiguously")
    end
    begin
      adapters.research_library_get({ "work_id" => "00000000-0000-4000-8000-000000000099" })
      raise "research get accepted a missing work"
    rescue RemoteWork::Error => error
      assert(!error.message.include?(library_root.to_s), "missing research work leaked the data root")
    end
  ensure
    ENV["TWO_HEAD_WU_RESEARCH_LIBRARY_ROOT"] = previous_root
    ENV["WU_RESEARCH_LIBRARY_BINDING_FILE"] = previous_binding
  end

  oversized = Pathname.new(temporary).join("oversized.pdf")
  File.open(oversized.to_s, "wb") { |file| file.truncate(RemoteWork::OwnerCapabilityAdapters::MAX_ARTIFACT_BYTES + 1) }
  oversized_adapter = RemoteWork::OwnerCapabilityAdapters.new(
    runtime_root: ROOT, source_root: ROOT, pipeline_root: ROOT,
    identity_adapter: identity_adapter, version: RemoteWork::VERSION
  )
  oversized_adapter.define_singleton_method(:research_artifact) do |_input|
    {
      "artifact_path" => oversized.to_s,
      "id" => "00000000-0000-4000-8000-000000000010",
      "work_id" => "00000000-0000-4000-8000-000000000011",
      "version_id" => "00000000-0000-4000-8000-000000000012",
      "sha256" => "a" * 64,
      "mime" => "application/pdf"
    }
  end
  begin
    oversized_adapter.research_library_export({
      "artifact_id" => "00000000-0000-4000-8000-000000000010", "expected_sha256" => "a" * 64
    })
    raise "oversized research artifact was accepted"
  rescue RemoteWork::Error => error
    assert(error.message.include?("50 MiB"), "oversized research artifact error is not explicit")
  end
end

adapter_registry = YAML.safe_load(
  ROOT.join("capabilities/remote-work/worker/capability-adapters.yaml").read(encoding: "UTF-8"),
  permitted_classes: [], aliases: false
).fetch("adapters")
research_adapters = adapter_registry.select { |item| item.fetch("capability_id").start_with?("research-library:") }
assert(research_adapters.map { |item| item.fetch("capability_id") }.sort == %w[research-library:export research-library:get research-library:search], "research adapter registry drift")
assert(research_adapters.all? { |item| item.dig("input_schema", "additionalProperties") == false }, "research adapter input schemas are not closed")
assert(!JSON.generate(research_adapters).match?(/data[_-]?root|database|artifact_path|raw_path/i), "research adapter registry exposes storage internals")
worker_confirmation = LTWWorker.new([])
export_adapter = research_adapters.find { |item| item.fetch("capability_id") == "research-library:export" }
begin
  worker_confirmation.send(
    :run_capability_adapter, export_adapter,
    {
      "artifact_id" => "00000000-0000-4000-8000-000000000010",
      "expected_sha256" => "a" * 64
    }, owner_confirmed: false
  )
  raise "worker exported a research artifact without owner confirmation"
rescue RemoteWork::Error => error
  assert(error.message.include?("owner confirmation"), "research export confirmation failure is ambiguous")
end

Dir.mktmpdir("remote-worker-cjk-patch-") do |temporary|
  root = Pathname.new(temporary)
  workspace = root.join("workspace")
  result = root.join("result")
  outer_head, _outer_error, outer_status = Open3.capture3("git", "-C", ROOT.to_s, "rev-parse", "HEAD")
  assert(outer_status.success?, "test could not capture the caller repository HEAD")
  FileUtils.mkdir_p(workspace.to_s)
  FileUtils.mkdir_p(result.to_s)
  worker = LTWWorker.new([])
  worker.send(:initialize_baseline_git, workspace)
  current_head, _current_error, current_status = Open3.capture3("git", "-C", ROOT.to_s, "rev-parse", "HEAD")
  assert(current_status.success? && current_head == outer_head, "worker baseline Git polluted the caller repository")
  assert(workspace.join(".git").directory?, "worker baseline Git was not created inside the temporary workspace")
  workspace.join("README.md").write("# 中文补丁\n", encoding: "UTF-8")
  previous_external = Encoding.default_external
  begin
    Encoding.default_external = Encoding::US_ASCII
    worker.send(:write_changes_patch, result, workspace)
    worker.send(:write_changed_files_archive, result, workspace)
  ensure
    Encoding.default_external = previous_external
  end
  patch = result.join("changes.patch").binread
  assert(patch.include?("中文补丁".b), "CJK bytes were lost while writing the result patch")
  changed = JSON.parse(result.join("changed-files.json").read(encoding: "UTF-8"))
  assert(changed.fetch("included").any? { |item| item.fetch("path") == "README.md" }, "changed file was not indexed")
  extracted = root.join("changed-files")
  RemoteWork::Archive.unpack(result.join("changed-files.tar.gz"), extracted)
  assert(extracted.join("README.md").read(encoding: "UTF-8") == "# 中文补丁\n", "changed file bytes were not preserved")
end

Dir.mktmpdir("remote-worker-final-text-") do |temporary|
  workspace = Pathname.new(temporary).join("workspace")
  FileUtils.mkdir_p(workspace.to_s)
  result_file = workspace.join("mini-result.md")
  result_file.write("# 结果\n", encoding: "UTF-8")
  worker = LTWWorker.new([])
  final_text = <<~MARKDOWN
    已新建 [mini-result.md](#{result_file})。
    外部资料仍保留为 [示例](https://example.com)。
  MARKDOWN
  sanitized = worker.send(:sanitize_final_text, final_text, workspace)
  assert(sanitized.include?("`mini-result.md`"), "temporary workspace link was not converted to a project-relative path")
  assert(!sanitized.include?(workspace.to_s), "temporary workspace path leaked into the final result")
  assert(sanitized.include?("[示例](https://example.com)"), "external Markdown link was changed")
end

Dir.mktmpdir("remote-work-unit-") do |temporary|
  root = Pathname.new(temporary)
  source = root.join("source")
  FileUtils.mkdir_p(source.join("src").to_s)
  FileUtils.mkdir_p(source.join("node_modules/pkg").to_s)
  source.join("src/input.txt").write("hello\n", encoding: "UTF-8")
  source.join(".env").write("SECRET=forbidden\n", encoding: "UTF-8")
  source.join("device.key").write("forbidden\n", encoding: "UTF-8")
  source.join("node_modules/pkg/cache.txt").write("forbidden\n", encoding: "UTF-8")
  archive = root.join("capsule.tar.gz")
  RemoteWork::Archive.pack_directory(source, archive)
  extracted = root.join("extracted")
  RemoteWork::Archive.unpack(archive, extracted)
  assert(extracted.join("src/input.txt").file?, "ordinary project file was not archived")
  assert(!extracted.join(".env").exist?, ".env leaked into capsule")
  assert(!extracted.join("device.key").exist?, "key file leaked into capsule")
  assert(!extracted.join("node_modules").exist?, "dependency cache leaked into capsule")

  malicious = root.join("malicious.tar.gz")
  Zlib::GzipWriter.open(malicious.to_s) do |gzip|
    Gem::Package::TarWriter.new(gzip) do |tar|
      tar.add_file_simple("../escape", 0o600, 1) { |file| file.write("x") }
    end
  end
  begin
    RemoteWork::Archive.unpack(malicious, root.join("unsafe"))
    raise "traversal archive was accepted"
  rescue RemoteWork::Error => error
    assert(error.message.include?("越界") || error.message.include?("不安全"), "traversal error was not explicit")
  end
  assert(!root.join("escape").exist?, "traversal archive wrote outside destination")
end

policy = YAML.safe_load(ROOT.join("capabilities/remote-work/policies/owner-only.yaml").read(encoding: "UTF-8"), permitted_classes: [], aliases: false)
assert(policy.dig("scope", "classmates") == "forbidden", "owner-only policy enabled classmates")
assert(policy.dig("jobs", "default_identity") == "owner-auto", "remote jobs do not request the owner automatic pool")
assert(policy.dig("jobs", "automatic_identity_members") == %w[owner-primary owner-secondary], "owner automatic pool membership drift")
assert(policy.dig("jobs", "silent_identity_fallback").nil?, "identity fallback belongs only in scope policy")
assert(policy.dig("scope", "silent_identity_fallback") == "owner-pool-only", "identity fallback escaped the owner-only pool")
assert(policy.dig("transport", "public_endpoint").start_with?("https://"), "production endpoint is not HTTPS")

skill = ROOT.join("capabilities/remote-work/skills/remote-work/SKILL.md").read(encoding: "UTF-8")
assert(skill.include?("two-head-wu-air modules") && skill.include?("two-head-wu-air module-pull"), "Skill does not teach the unified Air module commands")
assert(skill.include?("Air has no remote Mini administrator or arbitrary-shell capability"), "Skill grants or obscures remote Mini administration")
assert(skill.include?("including the owner notebook, do not ask for confirmation"), "Skill lost the notebook confirmation boundary")
assert(skill.include?("owner-password") && skill.include?("exactly four spaces"), "Skill lost the fixed local step-up boundary")

worker_source = ROOT.join("capabilities/remote-work/worker/ltw-worker").read(encoding: "UTF-8")
assert(worker_source.include?("last_model_sync.nil?"), "Mac mini worker no longer guarantees model sync at startup")
assert(worker_source.include?('binwrite(git_patch(workspace))'), "worker patch output is not binary-safe")
assert(worker_source.include?('ENV.fetch("WU_REMOTE_QUEUE", "air")'), "worker no longer defaults to the unified v2 Air queue")

member_queue_worker = LTWWorker.new(%w[--queue air --executor test])
member_queue_options = member_queue_worker.send(:parse_executor_options!)
assert(member_queue_options.fetch(:queue) == "air", "unified Air worker queue cannot be selected explicitly")
begin
  LTWWorker.new(%w[--queue mixed]).send(:parse_executor_options!)
  raise "worker accepted a mixed owner/member queue"
rescue RemoteWork::Error => error
  assert(error.message.include?("air or legacy-owner"), "mixed queue was rejected for the wrong reason")
end

Dir.mktmpdir("member-residue-root-") do |temporary|
  temporary_root = Pathname.new(temporary)
  worker = LTWWorker.new([])
  worker.instance_variable_set(:@member_runtime, { "temporary_root" => temporary_root })
  stale = temporary_root.join("ltw-member-job-stale")
  active = temporary_root.join("ltw-member-capability-active")
  unrelated = temporary_root.join("owner-data-must-remain")
  [stale, active, unrelated].each { |path| FileUtils.mkdir_p(path.to_s, mode: 0o700) }
  active_lock = File.open(active.join(LTWWorker::MEMBER_TEMPORARY_LOCK).to_s, File::RDWR | File::CREAT, 0o600)
  active_lock.flock(File::LOCK_EX)
  begin
    worker.send(:cleanup_member_task_residue!)
    assert(!stale.exist?, "member crash residue was not removed")
    assert(active.exist?, "active member task directory was removed")
    assert(unrelated.exist?, "member cleanup escaped its exact directory prefixes")
  ensure
    active_lock.close
  end
  worker.send(:cleanup_member_task_residue!)
  assert(!active.exist?, "unlocked member task residue was not removed")

  observed = nil
  worker.send(:with_member_temporary_directory, "ltw-member-job-") do |directory|
    observed = Pathname.new(directory)
    assert(observed.directory?, "member temporary directory was not created")
    assert(observed.join(LTWWorker::MEMBER_TEMPORARY_LOCK).file?, "member temporary directory has no active lock")
  end
  assert(observed && !observed.exist?, "member temporary directory survived normal completion")
end

deploy_source = ROOT.join("capabilities/remote-work/adapters/remote-work-deploy").read(encoding: "UTF-8")
assert(deploy_source.include?("IO.copy_stream(file, stdin)"), "deployment upload no longer streams through the fixed SSH channel")
assert(deploy_source.include?("UPLOAD_TIMEOUT_SECONDS = 120"), "deployment upload lost its finite timeout")

installer = ROOT.join("capabilities/remote-work/installer/install-air.command.in").read(encoding: "UTF-8")
assert(installer.include?("@@ENROLLMENT_TOKEN@@"), "installer template lost one-time token placeholder")
assert(installer.include?("@@RELEASE_PUBLIC_KEY_BASE64@@"), "installer template lost the pinned release public key placeholder")
assert(!installer.match?(/BEGIN (?:RSA |OPENSSH )?PRIVATE KEY/), "installer contains a private key")

member_launchd_template = ROOT.join("capabilities/remote-work/installer/com.twoheadwu.member-worker.plist.in")
member_launchd_renderer = ROOT.join("capabilities/remote-work/installer/render-member-worker-launchd")
member_plist, member_plist_error, member_plist_status = Open3.capture3(
  RbConfig.ruby, member_launchd_renderer.to_s,
  "--runtime-user", "_twoheadwumember",
  "--runtime-uid", "399",
  "--owner-uid", "501",
  "--runtime-root", "/Library/TwoHeadedWu/member-worker/runtime",
  "--release-root", "/Library/TwoHeadedWu/releases/0.12.0",
  "--codex-bin", "/Library/TwoHeadedWu/bin/codex",
  "--research-root", "/mnt/research/library",
  "--private-canary", "/home/example/.two-head-wu-member-deny-canary"
)
assert(member_plist_status.success?, "member launchd renderer failed: #{member_plist_error}")
assert(member_plist.include?("<string>air</string>"), "Air LaunchDaemon lost its unified v2 queue")
assert(member_plist.include?("<string>codex</string>"), "member LaunchDaemon did not select the config-free executor")
assert(member_plist.match?(/<key>Disabled<\/key>\s*<true\/>/), "member LaunchDaemon can start before explicit enable")
assert(!member_plist.include?("@@"), "member LaunchDaemon contains unresolved placeholders")
assert(!member_plist.match?(/token|password|private key/i), "member LaunchDaemon exposes secret material")
assert(member_launchd_template.read(encoding: "UTF-8").include?("WU_MEMBER_PRIVATE_CANARIES"), "member LaunchDaemon lost its owner-deny proof")
assert(member_plist.include?("<key>TWO_HEAD_WU_IDENTITY_ROOT</key>"), "member LaunchDaemon did not isolate the identity registry")
assert(member_plist.include?("/member-worker/runtime/agent-identity/codex-homes</string>"), "member LaunchDaemon Codex root does not match agent-identity")
assert(member_plist.include?("<key>TWO_HEAD_WU_RESEARCH_LIBRARY_ROOT</key>"), "member LaunchDaemon lost the explicit research binding")

member_installer = ROOT.join("capabilities/remote-work/installer/install-member-worker-runtime").read(encoding: "UTF-8")
assert(MemberWorkerInstaller::RUNTIME_ROOT == MemberWorkerInstaller::SYSTEM_ROOT.join("runtime"),
       "member runtime escaped its dedicated traversable system root")
assert(member_installer.include?("disabled-until-enrolled-and-air-health-passes"), "Air worker installer can activate before enrollment health")
assert(member_installer.include?("member runtime can read owner canary"), "member installer lost its canary verification")
assert(member_installer.include?("installed.dir == RUNTIME_ROOT.to_s"), "member installer does not reconcile an existing account home")
assert(member_installer.include?("RESEARCH_SANITIZE_SQL"), "member installer lost its sanitized research snapshot")
assert(!member_installer.include?("install_research_acl"), "member installer still attempts unsupported research-volume ACLs")
assert(!member_installer.match?(/BEGIN (?:RSA |OPENSSH )?PRIVATE KEY/), "member installer contains a private key")
assert(member_installer.include?("member worker enrollment: verified"), "Air worker installer has no enrollment health gate")
assert(member_installer.include?("token file was retained for diagnosis"), "member enrollment can destroy a token before a failed request is diagnosable")
assert(member_installer.include?("PROTECTED_NOTEBOOK_SUDOERS"), "Air worker installer omitted the exact owner notebook sudo rule")
assert(member_installer.include?("Air worker can read protected notebook config"), "Air worker installer lost the protected notebook deny probe")
assert(member_installer.include?("Air worker can traverse the personal-memory workspace"), "Air worker installer lost the live personal-memory deny probe")
assert(member_installer.include?("disable_service!\n    user, uid"), "member installer does not stop the old service before mutation")
assert(member_installer.include?("register-air-identity") && member_installer.include?("login-air-identity"),
       "member installer cannot prepare one fixed Codex identity per Air user")
assert(member_installer.include?("visudo"), "Air worker installer does not validate its sudo rule")

installer_instance = MemberWorkerInstaller.new([])
assert(installer_instance.send(:validated_air_identity, { identity: "owner-primary" }) == "owner-primary",
       "member installer rejected the owner Air identity alias")
begin
  installer_instance.send(:validated_air_identity, { identity: "Example/escape" })
  raise "member installer accepted an unsafe Air identity alias"
rescue RemoteWork::Error => error
  assert(error.message.include?("--identity"), "unsafe Air identity failed ambiguously")
end
disabled_services = <<~LAUNCHCTL
  disabled services = {
    "com.twoheadwu.member-worker" => disabled
  }
LAUNCHCTL
assert(
  installer_instance.send(:service_disabled?, disabled_output: disabled_services),
  "member installer did not recognize its persistent launchd disable override"
)
assert(
  !installer_instance.send(:service_disabled?, disabled_output: disabled_services.sub("=> disabled", "=> enabled")),
  "member installer treated an enabled launchd override as disabled"
)
assert(
  installer_instance.send(:service_disabled?, disabled_output: disabled_services.sub("=> disabled", "=> true")),
  "member installer rejected the boolean launchd disable format"
)
noowners_mounts = <<~MOUNTS
  /dev/disk3s1 on / (apfs, local, journaled)
  /dev/disk7s1 on /mnt/engineering (apfs, local, nodev, nosuid, journaled, noowners)
MOUNTS
assert(
  installer_instance.send(
    :mount_ignores_ownership?, Pathname.new("/mnt/engineering/private/workspace"), mount_output: noowners_mounts
  ),
  "member installer did not recognize an ownership-disabled volume"
)
assert(
  !installer_instance.send(:mount_ignores_ownership?, Pathname.new("/private/workspace"), mount_output: noowners_mounts),
  "member installer treated an ownership-enforcing volume as noowners"
)
acl_permissions = MemberWorkerInstaller::OWNER_WORKSPACE_DENY_PERMISSIONS.join(",")
acl_listing = "drwx------@ 2 owner staff 64 Sep 7 00:00 /private/workspace\n 0: user:_twoheadwumember deny #{acl_permissions}\n"
assert(
  installer_instance.send(
    :owner_workspace_deny_acl?, Pathname.new("/private/workspace"), "_twoheadwumember", acl_output: acl_listing
  ),
  "member installer did not recognize its exact personal-memory deny ACL"
)
assert(
  !installer_instance.send(
    :owner_workspace_deny_acl?, Pathname.new("/private/workspace"), "another-user", acl_output: acl_listing
  ),
  "member installer accepted another user's personal-memory deny ACL"
)

Dir.mktmpdir("member-worker-enrollment-token-") do |temporary|
  token_path = Pathname.new(temporary).join("member.token")
  token_value = "a" * 43
  token_path.write(token_value + "\n", encoding: "UTF-8")
  File.chmod(0o600, token_path.to_s)
  installer_instance = MemberWorkerInstaller.new([])
  checked_path, checked_token = installer_instance.send(:validated_enrollment_token, token_path.to_s, Process.euid)
  assert(checked_path == token_path.realpath && checked_token == token_value, "member enrollment token validation drifted")
  symlink = Pathname.new(temporary).join("member-link.token")
  File.symlink(token_path.to_s, symlink.to_s)
  begin
    installer_instance.send(:validated_enrollment_token, symlink.to_s, Process.euid)
    raise "member enrollment accepted a symlink token file"
  rescue RemoteWork::Error => error
    assert(error.message.include?("non-symlink"), "member enrollment rejected a symlink for the wrong reason")
  end
end

air_entry = ROOT.join("capabilities/remote-work/installer/air-wu").read(encoding: "UTF-8")
assert(air_entry.include?('client, "update", "auto"'), "Air entry no longer checks for a client update on use")
assert(air_entry.include?("WU_REMOTE_SKIP_ON_USE_UPDATE"), "Air entry lost its update recursion guard")

puts "remote-work unit tests ok"
