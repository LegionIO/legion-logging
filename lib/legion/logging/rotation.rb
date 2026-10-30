# frozen_string_literal: true

require 'fileutils'

module Legion
  module Logging
    # Size-based log rotation.
    #
    # Two cases are handled:
    #
    # 1. +log_file+ is configured: Legion opens the file itself and wraps it in a
    #    RotatingFile, which renames +legion.log+ -> +legion.log.1+ ... when it
    #    grows past +max_size_mb+ and reopens a fresh file.
    #
    # 2. stdout/stderr were redirected to a regular file by a supervisor
    #    (systemd StandardOutput=append:, shell >>, ...). Only append-mode
    #    regular files are eligible. StdioRotator remembers their original
    #    paths and reopens stdout/stderr after internal or external rotation.
    #    Checks are driven by logger writes, at most once per second; raw
    #    stdout/stderr writes alone do not trigger a check.
    #
    # Settings (Legion::Settings[:logging][:rotation] or setup(rotation: {...})):
    #   enabled:      true   # master switch
    #   max_size_mb:  100    # rotate when the active file exceeds this size
    #   max_files:    5      # rotated archives kept (legion.log.1 .. legion.log.5)
    #   stdio:        true   # also rotate stdout/stderr when redirected to a file
    module Rotation
      DEFAULTS = {
        enabled:     true,
        max_size_mb: 100,
        max_files:   5,
        stdio:       true
      }.freeze

      CHECK_INTERVAL = 1.0
      F_GETPATH = 50 # macOS fcntl(2) command; not exposed by the Fcntl module
      MAXPATHLEN = 1024

      class << self
        # Normalizes rotation settings. Accepts nil, false (disabled), or a Hash
        # with symbol or string keys. Missing keys fall back to DEFAULTS.
        def resolve(raw:)
          overrides = if raw == false
                        { enabled: false }
                      elsif raw.is_a?(Hash)
                        raw.transform_keys(&:to_sym)
                      else
                        {}
                      end
          merged = DEFAULTS.merge(overrides.slice(*DEFAULTS.keys))
          merged[:enabled] = merged[:enabled] != false
          merged[:stdio] = merged[:stdio] != false
          merged[:max_size_mb] = positive_number(merged[:max_size_mb], DEFAULTS[:max_size_mb])
          merged[:max_files] = positive_number(merged[:max_files], DEFAULTS[:max_files]).to_i
          merged[:max_files] = DEFAULTS[:max_files] unless merged[:max_files].positive?
          bytes = merged[:max_size_mb] * 1024 * 1024
          unless bytes.finite?
            merged[:max_size_mb] = DEFAULTS[:max_size_mb]
            bytes = merged[:max_size_mb] * 1024 * 1024
          end
          merged[:max_bytes] = [bytes.to_i, 1].max
          merged
        end

        # Reads rotation settings from Legion::Settings once it has loaded.
        # Guarded against re-entry because Settings may log while loading.
        def from_settings
          return nil unless defined?(Legion::Settings) && Legion::Settings.respond_to?(:[])
          return nil if Thread.current[:legion_logging_rotation_lookup]

          lookup_started = true
          Thread.current[:legion_logging_rotation_lookup] = true
          return nil if Legion::Settings.respond_to?(:loaded?) && !Legion::Settings.loaded?

          logging = Legion::Settings[:logging]
          logging[:rotation] if logging.is_a?(Hash)
        rescue StandardError => e
          warn("Legion::Logging::Rotation.from_settings failed: #{e.class}: #{e.message}")
          nil
        ensure
          Thread.current[:legion_logging_rotation_lookup] = nil if lookup_started
        end

        # Shifts path.(n-1) -> path.n ... path -> path.1, dropping the oldest.
        def shift_files(path:, max_files:)
          oldest = "#{path}.#{max_files}"
          FileUtils.rm(oldest, force: false) if File.exist?(oldest)
          (max_files - 1).downto(1) do |i|
            src = "#{path}.#{i}"
            File.rename(src, "#{path}.#{i + 1}") if File.exist?(src)
          end
          File.rename(path, "#{path}.1") if File.exist?(path)
        end

        # Returns the filesystem path behind an IO if it is a regular file opened
        # in append mode (launchd StandardOutPath, systemd append:, shell >>), or nil.
        # Non-append redirects (shell >) are left alone.
        def regular_file_path(io:)
          return nil unless io.respond_to?(:stat) && io.stat.file?
          return nil unless append_mode?(io: io)

          path = fd_path(io)
          return nil unless path && File.file?(path)
          return nil unless same_file?(io: io, path: path)

          path
        rescue StandardError => e
          warn("Legion::Logging::Rotation.regular_file_path failed: #{e.class}: #{e.message}")
          nil
        end

        def same_file?(io:, path:)
          return false unless File.exist?(path)

          io_stat = io.stat
          path_stat = File.stat(path)
          io_stat.ino == path_stat.ino && io_stat.dev == path_stat.dev
        rescue SystemCallError, IOError => e
          warn("Legion::Logging::Rotation.same_file? path=#{path} failed: #{e.class}: #{e.message}")
          false
        end

        def append_mode?(io:)
          require 'fcntl'
          io.fcntl(Fcntl::F_GETFL).anybits?(File::APPEND)
        rescue NotImplementedError, SystemCallError, IOError => e
          warn("Legion::Logging::Rotation.append_mode? failed: #{e.class}: #{e.message}")
          false
        end

        private

        def fd_path(io)
          if io.respond_to?(:path)
            path = File.expand_path(io.path)
            return path if same_file?(io: io, path: path)
          end

          if RUBY_PLATFORM.include?('darwin')
            require 'fcntl'
            buf = "\0" * MAXPATHLEN
            io.fcntl(F_GETPATH, buf)
            buf.unpack1('Z*')
          else
            proc_link = "/proc/self/fd/#{io.fileno}"
            File.readlink(proc_link) if File.symlink?(proc_link)
          end
        end

        def positive_number(value, default)
          number = Float(value)
          number.positive? && number.finite? ? number : default
        rescue ArgumentError, TypeError => e
          warn("Legion::Logging::Rotation invalid numeric limit: #{e.class}: #{e.message}")
          default
        end
      end
    end

    # Serializes writes through this device and detects external rotation at the
    # next check (inode change -> reopen). Separate devices and processes are
    # not coordinated by this instance's lock.
    class RotatingFile
      attr_reader :file_path, :max_bytes, :max_files

      def initialize(path:, max_bytes:, max_files:)
        @file_path = path
        @max_bytes = max_bytes
        @max_files = max_files
        @mutex = Mutex.new
        @next_check = 0.0
        @io = open_file
      end

      def write(*messages)
        @mutex.synchronize do
          rotate_if_needed
          @io.write(*messages)
        end
      end

      def flush
        @mutex.synchronize { @io.flush }
        self
      end

      def sync = true # rubocop:disable Naming/PredicateMethod -- IO#sync interface

      def sync=(_value); end

      def close
        @mutex.synchronize { @io.close unless @io.closed? }
      end

      def closed?
        @mutex.synchronize { @io.closed? }
      end

      def size
        @mutex.synchronize { @io.size }
      end

      def rotate!
        @mutex.synchronize { rotate_locked }
      end

      private

      def open_file
        file = File.new(@file_path, 'a')
        file.sync = true
        file
      end

      def rotate_if_needed
        now = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
        return if now < @next_check

        @next_check = now + Rotation::CHECK_INTERVAL
        unless Rotation.same_file?(io: @io, path: @file_path)
          reopen
          return
        end

        rotate_locked if @io.size >= @max_bytes
      rescue SystemCallError, IOError => e
        warn("Legion::Logging::RotatingFile#rotate_if_needed path=#{@file_path} failed: #{e.class}: #{e.message}")
      end

      def rotate_locked
        return false unless @io.stat.file?

        Rotation.shift_files(path: @file_path, max_files: @max_files)
        reopen
      end

      def reopen
        old = @io
        @io = open_file
        old.close unless old.closed?
      end
    end

    # Rotates the file that stdout (and stderr, when it points at the same file
    # or another regular file) was redirected to by the parent process.
    # One shared instance per process so multiple loggers don't double-rotate.
    class StdioRotator
      class << self
        def shared(max_bytes:, max_files:)
          @shared_mutex.synchronize do
            if @shared
              @shared.configure(max_bytes: max_bytes, max_files: max_files)
            else
              @shared = new(max_bytes: max_bytes, max_files: max_files)
            end
            @shared
          end
        end

        def reset!
          @shared_mutex.synchronize { @shared = nil }
        end
      end
      @shared_mutex = Mutex.new

      attr_reader :max_bytes, :max_files

      def initialize(max_bytes:, max_files:, stdout: $stdout, stderr: $stderr)
        @stdout = stdout
        @stderr = stderr
        @stdout_path = Rotation.regular_file_path(io: stdout)
        @stderr_path = Rotation.regular_file_path(io: stderr)
        @mutex = Mutex.new
        @next_check = 0.0
        configure(max_bytes: max_bytes, max_files: max_files)
      end

      def configure(max_bytes:, max_files:)
        @mutex.synchronize do
          @max_bytes = max_bytes
          @max_files = max_files
        end
      end

      def write(*messages)
        @mutex.synchronize do
          rotate_if_needed
          @stdout.write(*messages)
        end
      end

      def flush
        @mutex.synchronize { @stdout.flush }
        self
      end

      # Never close the process stdout.
      def close; end

      def closed? = false

      def sync = true # rubocop:disable Naming/PredicateMethod -- IO#sync interface

      def sync=(_value); end

      def rotate!
        @mutex.synchronize { rotate_stdio(force: true) }
      end

      private

      def rotate_if_needed
        now = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
        return if now < @next_check

        @next_check = now + Rotation::CHECK_INTERVAL
        rotate_stdio
      rescue SystemCallError, IOError => e
        warn("Legion::Logging::StdioRotator#rotate_if_needed failed: #{e.class}: #{e.message}")
      end

      def rotate_stdio(force: false)
        @stdout.flush if @stdout_path
        @stderr.flush if @stderr_path
        shared = shared_file?
        out_changed = rotate_stream(io: @stdout, path: @stdout_path, force: force)

        if shared && out_changed
          @stderr.reopen(@stdout) unless @stderr.equal?(@stdout)
          @stderr.sync = true
          return true
        end

        err_changed = rotate_stream(io: @stderr, path: @stderr_path, force: force) unless shared
        out_changed || !!err_changed
      end

      def shared_file?
        return false unless @stdout_path && @stderr_path

        out_stat = @stdout.stat
        err_stat = @stderr.stat
        out_stat.ino == err_stat.ino && out_stat.dev == err_stat.dev
      end

      def rotate_stream(io:, path:, force:)
        return false unless path

        if Rotation.same_file?(io: io, path: path)
          return false unless force || io.stat.size >= @max_bytes

          Rotation.shift_files(path: path, max_files: @max_files)
        end
        io.reopen(path, 'a')
        io.sync = true
        true
      rescue SystemCallError, IOError => e
        warn("Legion::Logging::StdioRotator path=#{path} failed: #{e.class}: #{e.message}")
        false
      end
    end
  end
end
