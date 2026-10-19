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
    #    (launchd StandardOutPath, systemd StandardOutput=append:, nohup, ...).
    #    The supervisor opened the file, so nothing outside the process can
    #    rotate it safely. StdioRotator detects the path behind fd 1/2, renames
    #    the file and re-points $stdout/$stderr at a fresh file with IO#reopen,
    #    which also captures raw stderr output (thread crashes, C warnings).
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
        def resolve(raw = nil)
          return DEFAULTS.merge(enabled: false) if raw == false

          overrides = raw.is_a?(Hash) ? raw.transform_keys(&:to_sym) : {}
          merged = DEFAULTS.merge(overrides.slice(*DEFAULTS.keys))
          merged[:enabled] = merged[:enabled] != false
          merged[:stdio] = merged[:stdio] != false
          merged[:max_size_mb] = positive_number(merged[:max_size_mb], DEFAULTS[:max_size_mb])
          merged[:max_files] = positive_number(merged[:max_files], DEFAULTS[:max_files]).to_i
          merged[:max_bytes] = (merged[:max_size_mb] * 1024 * 1024).to_i
          merged
        end

        # Reads rotation settings from Legion::Settings once it has loaded.
        # Guarded against re-entry because Settings may log while loading.
        def from_settings
          return nil unless defined?(Legion::Settings) && Legion::Settings.respond_to?(:[])
          return nil if Legion::Settings.respond_to?(:loaded?) && !Legion::Settings.loaded?
          return nil if Thread.current[:legion_logging_rotation_lookup]

          Thread.current[:legion_logging_rotation_lookup] = true
          logging = Legion::Settings[:logging]
          logging[:rotation] if logging.is_a?(Hash)
        rescue StandardError => e
          warn("Legion::Logging::Rotation.from_settings failed: #{e.class}: #{e.message}")
          nil
        ensure
          Thread.current[:legion_logging_rotation_lookup] = nil
        end

        # Shifts path.(n-1) -> path.n ... path -> path.1, dropping the oldest.
        def shift_files(path, max_files)
          FileUtils.rm_f("#{path}.#{max_files}")
          (max_files - 1).downto(1) do |i|
            src = "#{path}.#{i}"
            File.rename(src, "#{path}.#{i + 1}") if File.exist?(src)
          end
          File.rename(path, "#{path}.1") if File.exist?(path)
        end

        # Returns the filesystem path behind an IO if it is a regular file opened
        # in append mode (launchd StandardOutPath, systemd append:, shell >>), or nil.
        # Non-append redirects (shell >) are left alone.
        def regular_file_path(io)
          return nil unless io.respond_to?(:stat) && io.stat.file?
          return nil unless append_mode?(io)

          path = fd_path(io)
          return nil unless path && File.file?(path)
          return nil unless same_file?(io, path)

          path
        rescue StandardError => e
          warn("Legion::Logging::Rotation.regular_file_path failed: #{e.class}: #{e.message}")
          nil
        end

        def same_file?(io, path)
          io_stat = io.stat
          path_stat = File.stat(path)
          io_stat.ino == path_stat.ino && io_stat.dev == path_stat.dev
        rescue SystemCallError, IOError
          false
        end

        def append_mode?(io)
          require 'fcntl'
          io.fcntl(Fcntl::F_GETFL).anybits?(File::APPEND)
        rescue NotImplementedError, SystemCallError, IOError
          false
        end

        private

        def fd_path(io)
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
          number.positive? ? number : default
        rescue ArgumentError, TypeError
          default
        end
      end
    end

    # An append-mode File that rotates itself by size. Safe for concurrent
    # writers in one process and detects rotation done by another instance
    # writing the same path (inode change -> reopen).
    class RotatingFile
      attr_reader :file_path, :max_bytes, :max_files

      def initialize(path, max_bytes:, max_files:)
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
        @io.closed?
      end

      def size
        @io.size
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
        unless Rotation.same_file?(@io, @file_path)
          reopen
          return
        end

        rotate_locked if @io.size >= @max_bytes
      rescue SystemCallError, IOError => e
        warn("Legion::Logging::RotatingFile#rotate_if_needed path=#{@file_path} failed: #{e.class}: #{e.message}")
      end

      def rotate_locked
        Rotation.shift_files(@file_path, @max_files)
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
        @mutex = Mutex.new
        @next_check = 0.0
        configure(max_bytes: max_bytes, max_files: max_files)
      end

      def configure(max_bytes:, max_files:)
        @max_bytes = max_bytes
        @max_files = max_files
      end

      def write(*messages)
        @mutex.synchronize do
          rotate_if_needed
          @stdout.write(*messages)
        end
      end

      def flush
        @stdout.flush
        self
      end

      # Never close the process stdout.
      def close; end

      def closed? = false

      def sync = true # rubocop:disable Naming/PredicateMethod -- IO#sync interface

      def sync=(_value); end

      def rotate!
        @mutex.synchronize { rotate_stdio }
      end

      private

      def rotate_if_needed
        now = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
        return if now < @next_check

        @next_check = now + Rotation::CHECK_INTERVAL
        @stdout.flush
        stat = @stdout.stat
        rotate_stdio if stat.file? && stat.size >= @max_bytes
      rescue SystemCallError, IOError => e
        warn("Legion::Logging::StdioRotator#rotate_if_needed failed: #{e.class}: #{e.message}")
      end

      def rotate_stdio # rubocop:disable Naming/PredicateMethod
        out_path = Rotation.regular_file_path(@stdout)
        return false unless out_path

        err_path = Rotation.regular_file_path(@stderr)
        err_shared = err_path == out_path

        @stdout.flush
        @stderr.flush if err_path
        Rotation.shift_files(out_path, @max_files)
        @stdout.reopen(out_path, 'a')
        @stdout.sync = true

        if err_shared
          @stderr.reopen(@stdout)
        elsif err_path && File.size(err_path) >= @max_bytes
          Rotation.shift_files(err_path, @max_files)
          @stderr.reopen(err_path, 'a')
        end
        @stderr.sync = true if err_path
        true
      end
    end
  end
end
