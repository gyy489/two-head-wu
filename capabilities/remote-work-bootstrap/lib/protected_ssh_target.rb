# frozen_string_literal: true

require "open3"

module ProtectedSshTarget
  SERVICE = "two-head-wu.remote-work-bootstrap"
  ACCOUNT = "edge-server-ssh-target"

  module_function

  def read(environment_name)
    if ENV.key?(environment_name)
      value = ENV.fetch(environment_name, "").strip
      return [value, "environment"]
    end
    return ["", "unavailable"] unless RUBY_PLATFORM.include?("darwin")

    stdout, _stderr, status = Open3.capture3(
      "security", "find-generic-password", "-s", SERVICE, "-a", ACCOUNT, "-w"
    )
    [status.success? ? stdout.strip : "", status.success? ? "keychain" : "unavailable"]
  rescue Errno::ENOENT
    ["", "unavailable"]
  end

  def install(value)
    raise "macOS Keychain is required" unless RUBY_PLATFORM.include?("darwin")

    _stdout, _stderr, status = Open3.capture3(
      "security", "add-generic-password", "-U", "-s", SERVICE, "-a", ACCOUNT, "-w", value
    )
    raise "cannot store the protected SSH target in macOS Keychain" unless status.success?

    true
  rescue Errno::ENOENT
    raise "macOS Keychain command is unavailable"
  end
end
