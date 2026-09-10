# frozen_string_literal: true

require "pathname"

module RemoteWork
  class MemberSandbox
    SYSTEM_READ_ROOTS = %w[
      /System
      /usr
      /bin
      /sbin
      /Library/Apple
      /Library/Preferences/Logging
      /private/etc
      /private/var/db/timezone
      /dev
    ].freeze

    def initialize(executable: "/usr/bin/sandbox-exec")
      @executable = Pathname.new(executable)
    end

    def command(command, workspace:, runtime_home:, codex_home:)
      raise Error, "member sandbox is available only on macOS" unless RUBY_PLATFORM.include?("darwin")
      validate_sandbox_executable!
      roots = [workspace, runtime_home, codex_home].map { |value| real_directory(value) }
      command_executable = Pathname.new(command.fetch(0)).realpath
      profile_path = roots.fetch(1).join("member-seatbelt.sb")
      profile_path.open("w", 0o600) { |file| file.write(profile(roots, command_executable)) }
      [@executable.to_s, "-f", profile_path.to_s, *command]
    rescue Errno::EACCES, Errno::ENOENT
      raise Error, "member command executable is unavailable"
    end

    def profile(roots, command_executable)
      workspace, runtime_home, codex_home = roots
      read_roots = SYSTEM_READ_ROOTS.map { |value| Pathname.new(value) }
      read_roots.concat([workspace, runtime_home, codex_home])
      read_rules = read_roots.uniq.map { |path| "  (subpath #{seatbelt_string(path)})" }.join("\n")
      read_rules << "\n  (literal #{seatbelt_string(command_executable)})"
      write_rules = [workspace, runtime_home].map { |path| "  (subpath #{seatbelt_string(path)})" }.join("\n")
      <<~PROFILE
        (version 1)
        (deny default)
        (import "system.sb")
        (allow process*)
        (allow network-outbound)
        (allow file-read*
        #{read_rules})
        (allow file-write*
        #{write_rules}
          (literal "/dev/null"))
      PROFILE
    end

    private

    def validate_sandbox_executable!
      stat = @executable.stat
      unless @executable.absolute? && stat.file? && @executable.executable? && stat.uid.zero? && (stat.mode & 0o022).zero?
        raise Error, "member sandbox executable is not a trusted system binary"
      end
    rescue Errno::EACCES, Errno::ENOENT
      raise Error, "member sandbox executable is unavailable"
    end

    def real_directory(value)
      path = Pathname.new(value).realpath
      raise Error, "member sandbox root is not a directory" unless path.directory?
      path
    rescue Errno::EACCES, Errno::ENOENT
      raise Error, "member sandbox root is unavailable"
    end

    def seatbelt_string(path)
      value = path.to_s
      raise Error, "member sandbox path contains control characters" if value.match?(/[\x00-\x1f\x7f]/)
      value.dump
    end
  end
end
