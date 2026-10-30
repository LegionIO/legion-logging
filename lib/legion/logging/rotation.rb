# frozen_string_literal: true

require 'fileutils'

module Legion
  module Logging
    # Settings and descriptor detection shared by the byte-capped file and stdio sinks.
    module Rotation
      DEFAULTS = {
        enabled:     true,
        max_size_mb: 100,
        max_files:   5,
        stdio:       true
      }.freeze

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
  end
end

require_relative 'rotating_file'
require_relative 'stdio_rotator'
