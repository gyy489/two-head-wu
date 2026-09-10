# frozen_string_literal: true

require "etc"
require "pathname"

module RemoteWork
  class MemberRuntimeGuard
    REQUIRED_ENV = %w[
      WU_MEMBER_RUNTIME_USER
      WU_MEMBER_RUNTIME_UID
      WU_MEMBER_OWNER_UID
      WU_MEMBER_RUNTIME_ROOT
      WU_MEMBER_CODEX_ROOT
      WU_MEMBER_RELEASE_ROOT
      WU_MEMBER_PRIVATE_CANARIES
      WU_REMOTE_CODEX_BIN
    ].freeze

    def initialize(environment: ENV, effective_uid: Process.euid, username: nil, canary_probe: nil, source_root: nil)
      @environment = environment
      @effective_uid = effective_uid
      @username = username || Etc.getpwuid(effective_uid).name
      @canary_probe = canary_probe || method(:can_read?)
      @source_root = Pathname.new(source_root).realpath if source_root
    end

    def verify!
      missing = REQUIRED_ENV.reject { |key| !@environment[key].to_s.empty? }
      raise Error, "member runtime isolation is not configured" unless missing.empty?

      expected_uid = exact_uid(@environment.fetch("WU_MEMBER_RUNTIME_UID"), "member runtime")
      owner_uid = exact_uid(@environment.fetch("WU_MEMBER_OWNER_UID"), "owner")
      expected_user = @environment.fetch("WU_MEMBER_RUNTIME_USER")
      unless expected_uid == @effective_uid && expected_user == @username && expected_uid != 0 && expected_uid != owner_uid
        raise Error, "member runtime must use the registered non-owner system identity"
      end

      runtime_root = private_directory(@environment.fetch("WU_MEMBER_RUNTIME_ROOT"), "member runtime root")
      release_root = immutable_directory(@environment.fetch("WU_MEMBER_RELEASE_ROOT"), "member release root")
      if @source_root && release_root != @source_root
        raise Error, "member worker is not running from the registered immutable release"
      end
      codex_root = private_directory(@environment.fetch("WU_MEMBER_CODEX_ROOT"), "member Codex root")
      require_descendant!(codex_root, runtime_root, "member Codex root")
      temporary_root = private_directory(runtime_root.join("tmp"), "member temporary root")
      worker_home = private_directory(@environment.fetch("WU_REMOTE_WORKER_HOME"), "member worker home")
      require_descendant!(worker_home, runtime_root, "member worker home")
      immutable_executable(@environment.fetch("WU_REMOTE_CODEX_BIN"))
      verify_private_canaries!

      {
        "runtime_root" => runtime_root,
        "release_root" => release_root,
        "codex_root" => codex_root,
        "temporary_root" => temporary_root,
        "worker_home" => worker_home,
        "uid" => expected_uid,
        "user" => expected_user
      }.freeze
    end

    def verify_member_codex_home!(value, runtime)
      path = private_directory(value, "member Codex home")
      require_descendant!(path, runtime.fetch("codex_root"), "member Codex home")
      path
    end

    private

    def exact_uid(value, label)
      text = value.to_s
      raise Error, "#{label} uid is invalid" unless text.match?(/\A(?:0|[1-9][0-9]{0,9})\z/)
      Integer(text, 10)
    end

    def private_directory(value, label)
      path = absolute_real_path(value, label)
      stat = path.stat
      unless stat.directory? && stat.uid == @effective_uid && (stat.mode & 0o077).zero?
        raise Error, "#{label} must be a private directory owned by the member runtime"
      end
      path
    rescue Errno::EACCES, Errno::ENOENT
      raise Error, "#{label} is unavailable"
    end

    def immutable_executable(value)
      path = absolute_real_path(value, "member Codex executable")
      stat = path.stat
      unless stat.file? && path.executable? && stat.uid != @effective_uid && (stat.mode & 0o022).zero?
        raise Error, "member Codex executable must be immutable to the member runtime"
      end
      path
    rescue Errno::EACCES, Errno::ENOENT
      raise Error, "member Codex executable is unavailable"
    end

    def immutable_directory(value, label)
      path = absolute_real_path(value, label)
      stat = path.stat
      unless stat.directory? && stat.uid != @effective_uid && (stat.mode & 0o022).zero?
        raise Error, "#{label} must be immutable to the member runtime"
      end
      path
    rescue Errno::EACCES, Errno::ENOENT
      raise Error, "#{label} is unavailable"
    end

    def absolute_real_path(value, label)
      path = Pathname.new(value.to_s)
      raise Error, "#{label} must be absolute" unless path.absolute?
      clean = path.cleanpath
      real = clean.realpath
      raise Error, "#{label} may not traverse symbolic links" unless clean == real
      real
    rescue Errno::EACCES, Errno::ENOENT
      raise Error, "#{label} is unavailable"
    end

    def require_descendant!(path, parent, label)
      prefix = parent.to_s + File::SEPARATOR
      raise Error, "#{label} escaped the member runtime root" unless path.to_s.start_with?(prefix)
    end

    def verify_private_canaries!
      paths = @environment.fetch("WU_MEMBER_PRIVATE_CANARIES").split(File::PATH_SEPARATOR).reject(&:empty?)
      raise Error, "owner private canaries are not configured" if paths.empty?
      paths.each do |value|
        path = Pathname.new(value)
        unless path.absolute? && path.cleanpath == path && !@canary_probe.call(path)
          raise Error, "member runtime can read an owner private canary"
        end
      end
    end

    def can_read?(path)
      File.open(path.to_s, "rb") { |file| file.read(1) }
      true
    rescue Errno::EACCES, Errno::EPERM
      false
    rescue Errno::ENOENT
      true
    end
  end
end
