#!/usr/bin/env ruby
# frozen_string_literal: true

require "open3"
require "yaml"

ROOT = File.expand_path("../../..", __dir__)
ADAPTER = File.join(ROOT, "capabilities/remote-work-bootstrap/adapters/remote-work-bootstrap")

def assert(condition, message)
  raise message unless condition
end

def invoke(*arguments, env: {})
  Open3.capture3(env, ADAPTER, *arguments)
end

stdout, stderr, status = invoke("health")
assert(status.success?, "health failed: #{stderr}")
assert(stdout.include?("remote-work-bootstrap health ok"), "health output is incomplete")

source = File.read(ADAPTER, encoding: "UTF-8")
%w[--target --host --user --key --config --command --path].each do |option|
  assert(!source.include?("item.on(\"#{option}"), "adapter accepts forbidden option #{option}")
end
assert(source.include?("StrictHostKeyChecking=yes"), "SSH host-key verification is not strict")
assert(source.include?("PasswordAuthentication=no"), "password authentication is not disabled")
assert(source.include?("/srv/two-head-wu"), "fixed runtime root is missing")
assert(source.include?("twoheadwu"), "shared system identity is missing")
assert(!source.match?(/rm\s+-rf|nginx|\/var\/www/), "bootstrap source contains a website or destructive path")

_stdout, stderr, status = invoke("auth-check", "--project", "two-head-wu", env: { "TWO_HEAD_WU_ALIYUN_SSH_TARGET" => "" })
assert(!status.success?, "auth-check succeeded without a protected target")
assert(stderr.include?("protected SSH target is not installed"), "missing-target error is not redacted")

_stdout, stderr, status = invoke("bootstrap", "--project", "two-head-wu")
assert(!status.success?, "bootstrap succeeded without explicit approval")
assert(stderr.include?("--approve is required"), "bootstrap did not require explicit approval")

policy = YAML.safe_load(File.read(File.join(ROOT, "catalog/policies/remote-work-bootstrap.yaml"), encoding: "UTF-8"), permitted_classes: [], aliases: false)
assert(policy.dig("remote_runtime", "system_identity") == "twoheadwu", "policy lost shared system identity")
assert(policy.dig("remote_runtime", "sudo") == "forbidden", "system identity unexpectedly has sudo")
assert(policy.dig("website_guard", "content_change") == "forbidden", "website content is not protected")

puts "remote-work-bootstrap tests ok"
