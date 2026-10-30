# frozen_string_literal: true

module Legion
  module Logging
    # Every cooperating writer for a path must use the same limits. The stable
    # lock file coordinates separate devices/processes and must not be removed.
    class RotatingFile
      BUFFER_BYTES = 64 * 1024

      attr_reader :file_path, :max_bytes, :max_files

      def initialize(path:, max_bytes:, max_files:)
        unless max_bytes.is_a?(Integer) && max_bytes.positive? && max_files.is_a?(Integer) && max_files.positive?
          raise ArgumentError, 'max_bytes and max_files must be positive integers'
        end

        @file_path = File.expand_path(path)
        @max_bytes = max_bytes
        @max_files = max_files
        @mutex = Mutex.new
        @archive_pattern = /\A#{Regexp.escape(File.basename(@file_path))}\.([1-9]\d*)\z/
        @needs_normalization = true
        @closed = false
        synchronize_path { normalize_locked }
      rescue StandardError
        begin
          @io&.close
        ensure
          @lock_io&.close
        end
        raise
      end

      def write(*messages)
        raise ArgumentError, 'wrong number of arguments (given 0, expected 1+)' if messages.empty?

        synchronize_path do
          normalize_locked if @needs_normalization
          next @io.write(*messages) unless @regular

          trim_file(path: @file_path) if @io.size > @max_bytes
          messages.sum { |message| write_message(message: message.to_s) }
        end
      end

      def flush
        @mutex.synchronize do
          raise IOError, 'closed stream' if @closed

          @io&.flush
        end
        self
      end

      def sync = true # rubocop:disable Naming/PredicateMethod -- IO#sync interface

      def sync=(_value); end

      def close
        @mutex.synchronize do
          return if @closed

          @closed = true
          begin
            @io&.close
          ensure
            @lock_io.close if @lock_io && !@lock_io.closed?
          end
        end
      end

      def closed?
        @mutex.synchronize { @closed }
      end

      def size
        synchronize_path { @io.size }
      end

      def rotate!
        synchronize_path do
          normalize_locked if @needs_normalization
          rotate_locked!
        end
      end

      def configure(max_bytes:, max_files:)
        unless max_bytes.is_a?(Integer) && max_bytes.positive? && max_files.is_a?(Integer) && max_files.positive?
          raise ArgumentError, 'max_bytes and max_files must be positive integers'
        end

        synchronize_path do
          @max_bytes = max_bytes
          @max_files = max_files
          @needs_normalization = true
          normalize_locked
        end
        self
      end

      private

      def open_file
        file = File.new(@file_path, 'ab')
        file.sync = true
        file
      end

      def synchronize_path
        @mutex.synchronize do
          raise IOError, 'closed stream' if @closed

          lock_path if @lock_io || File.file?(@file_path) || !File.exist?(@file_path)
          begin
            reopen_if_replaced
            if @regular && !@lock_io
              @io.close
              @io = nil
              lock_path
              reopen_if_replaced
            end
            yield
          ensure
            begin
              # Idle devices must not pin archives after another writer unlinks
              # them. Release every regular data-file FD before the path lock.
              if @regular && @io
                @io.close
                @io = nil
              end
            ensure
              @lock_io&.flock(File::LOCK_UN)
            end
          end
        end
      end

      def lock_path
        # flock locks are inherited across fork with the open file description.
        # Reopen in the child so its lock competes with its parent's lock.
        if @lock_io && @lock_pid != ::Process.pid
          @lock_io.close
          @lock_io = nil
        end
        @lock_io ||= File.open("#{@file_path}.lock", File::RDWR | File::CREAT, 0o600)
        @lock_pid = ::Process.pid
        raise IOError, 'could not acquire log rotation lock' unless @lock_io.flock(File::LOCK_EX)
      end

      def reopen_if_replaced
        if @io
          current = @io.stat
          target = File.stat(@file_path) if File.exist?(@file_path)
          return if target && current.dev == target.dev && current.ino == target.ino
        end

        replace_io
      end

      def replace_io
        previous = @io
        @io = open_file
        current = @io.stat
        @regular = current.file?
        @needs_normalization ||= @file_dev != current.dev || @file_ino != current.ino
        @file_dev = current.dev
        @file_ino = current.ino
        previous&.close
      end

      def normalize_locked
        if @regular
          trim_file(path: @file_path)
          directory = File.dirname(@file_path)
          Dir.each_child(directory) do |name|
            match = @archive_pattern.match(name)
            next unless match

            archive = File.join(directory, name)
            if match[1].to_i > @max_files
              File.unlink(archive)
            else
              trim_file(path: archive)
            end
          end
        end
        @needs_normalization = false
      end

      def trim_file(path:)
        stat = File.stat(path)
        return unless stat.file? && stat.size > @max_bytes

        # Move the retained tail toward the beginning without a temporary file
        # or a full-file allocation. Forward copies cannot overwrite unread data.
        File.open(path, 'r+b') do |file|
          source_offset = file.size - @max_bytes
          offset = 0
          buffer = +''.b
          while offset < @max_bytes
            file.seek(source_offset + offset)
            chunk = file.read([BUFFER_BYTES, @max_bytes - offset].min, buffer)
            raise IOError, 'log file changed while trimming its retained tail' if chunk.nil? || chunk.empty?

            file.seek(offset)
            offset += file.write(chunk)
          end
          file.truncate(@max_bytes)
        end
      end

      def write_message(message:)
        offset = 0
        available = @max_bytes - @io.size
        while offset < message.bytesize
          unless available.positive?
            rotate_locked!
            available = @max_bytes
          end
          length = [message.bytesize - offset, available, BUFFER_BYTES].min
          chunk = offset.zero? && length == message.bytesize ? message : message.byteslice(offset, length)
          written = @io.write(chunk)
          offset += written
          available -= written
        end
        offset
      end

      def rotate_locked! # rubocop:disable Naming/PredicateMethod -- Renames files; false means a nonregular destination.
        return false unless @regular

        Rotation.shift_files(path: @file_path, max_files: @max_files)
        replace_io
        @needs_normalization = false
        true
      end
    end
  end
end
