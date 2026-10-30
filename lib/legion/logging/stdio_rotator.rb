# frozen_string_literal: true

module Legion
  module Logging
    # The descriptors themselves become pipe writers, including writes which do
    # not pass through Ruby's Logger. Only the drain thread owns the file sink.
    class StdioRotator
      class << self
        attr_reader :current

        def shared(max_bytes:, max_files:)
          inherited = @current
          if inherited && !inherited.owned?
            raise IOError, 'cannot change the policy of an inherited stdio capture' unless inherited.max_bytes == max_bytes && inherited.max_files == max_files

            return inherited
          end

          @shared_mutex.synchronize do
            return @current.configure(max_bytes: max_bytes, max_files: max_files) if @current

            capture = new(max_bytes: max_bytes, max_files: max_files)
            @current = capture if capture.capturing?
          end
        end

        def reset!(timeout: 2)
          return false unless timeout.nil? ? @shared_mutex.lock : @shared_mutex.try_lock

          begin
            return true unless @current
            return false unless @current.shutdown(timeout: timeout)

            @current = nil
            true
          ensure
            @shared_mutex.unlock
          end
        end
      end
      @shared_mutex = Mutex.new

      attr_reader :max_bytes, :max_files

      def initialize(max_bytes:, max_files:, stdout: $stdout, stderr: $stderr)
        @stdout = stdout
        @streams = [stdout, stderr].uniq(&:object_id)
        @lifecycle = Mutex.new
        @captures = []
        @closed = false
        @owner_pid = ::Process.pid
        @max_bytes = max_bytes
        @max_files = max_files
        eligible = @streams.filter_map do |stream|
          path = Rotation.regular_file_path(io: stream)
          stream.flush if path
          [stream, path, stream.stat] if path
        end
        eligible.group_by { |_, _, stat| [stat.dev, stat.ino] }.each_value do |group|
          @captures << StdioCapture.new(path: group.first[1], streams: group.map(&:first), max_bytes: max_bytes, max_files: max_files)
        end
        @captures.each(&:attach)
        @captures.each(&:release_backups)
      rescue StandardError
        @captures.reverse_each(&:rollback)
        raise
      end

      def capturing? = !@captures.empty? && !@closed

      def owned? = @owner_pid == ::Process.pid

      def configure(max_bytes:, max_files:)
        raise IOError, 'cannot configure an inherited stdio capture' unless owned?

        @lifecycle.synchronize do
          raise IOError, 'closed stdio capture' if @closed

          @captures.each { |capture| capture.command(type: :configure, arguments: { max_bytes: max_bytes, max_files: max_files }) }
          @max_bytes = max_bytes
          @max_files = max_files
        end
        self
      end

      def write(*messages)
        if @closed
          current = self.class.current
          return current.write(*messages) if current && !current.equal?(self) && current.stdout.equal?(@stdout)

          return @stdout.write(*messages)
        end

        @captures.each(&:check_failure!) if owned?
        @stdout.write(*messages)
      rescue IOError, SystemCallError
        @captures.each(&:check_failure!) if owned? && !@closed
        raise
      end

      def flush(timeout: 2)
        return false unless owned?

        if @closed
          current = self.class.current
          return current.flush(timeout: timeout) if current && !current.equal?(self) && current.stdout.equal?(@stdout)

          @stdout.flush
          return self
        end

        deadline = monotonic_time + timeout if timeout
        @captures.each { |capture| return false unless capture.flush(deadline: deadline) }
        @stdout.flush unless @captures.any? { |capture| capture.includes?(stream: @stdout) }
        self
      end

      # Logger borrows process stdio. Only explicit shutdown/reset! detaches it.
      def close; end

      def closed? = @closed

      def sync = true # rubocop:disable Naming/PredicateMethod -- IO#sync interface

      def sync=(_value); end

      def rotate!
        raise IOError, 'cannot rotate an inherited stdio capture' unless owned?

        @lifecycle.synchronize do
          raise IOError, 'closed stdio capture' if @closed

          @captures.each { |capture| capture.command(type: :rotate!, arguments: {}) }
          !@captures.empty?
        end
      end

      def shutdown(timeout: 2)
        return false unless owned?
        return false unless timeout.nil? ? @lifecycle.lock : @lifecycle.try_lock

        deadline = monotonic_time + timeout if timeout
        detached = false
        begin
          return true if @closed
          return false unless @captures.all? { |capture| capture.pause(deadline: deadline) }

          detached = true
          @closed = drain_and_detach!(deadline: deadline)
        ensure
          begin
            unless @closed
              @captures.each(&:attach) if detached
              @captures.each(&:resume)
            end
          ensure
            @lifecycle.unlock
          end
        end
      end

      protected

      attr_reader :stdout

      private

      def drain_and_detach!(deadline:)
        @captures.each(&:restore)
        @captures.each(&:resume)
        # Include bytes written to the old descriptors during restoration.
        return false unless @captures.all? { |capture| capture.pause(deadline: deadline) }

        # A final drain may itself rotate: restore the current active inode.
        @captures.each(&:restore)
        @captures.all? { |capture| capture.finish!(deadline: deadline) }
      end

      def monotonic_time
        ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
      end
    end

    # One reader and one bounded control pipe per distinct inherited file.
    # Commands occupy a single slot; bytes are never queued in Ruby.
    class StdioCapture
      READ_BYTES = 16 * 1024

      def initialize(path:, streams:, max_bytes:, max_files:)
        @path = path
        @streams = streams
        @state = Mutex.new
        @changed = ConditionVariable.new
        @requested_flush = 0
        @completed_flush = 0
        @backups = []
        @properties = streams.map { |stream| [stream.sync, stream.close_on_exec?, stream.external_encoding, stream.internal_encoding] }
        streams.each { |stream| @backups << stream.dup }
        @sink = RotatingFile.new(path: path, max_bytes: max_bytes, max_files: max_files)
        @reader, @writer = IO.pipe
        @wake_reader, @wake_writer = IO.pipe
        @writer.binmode
        @writer.sync = true
        @worker = Thread.new do
          Thread.current.report_on_exception = false
          drain
        end
      rescue StandardError
        begin
          close_handles
        ensure
          release_backups
        end
        raise
      end

      def includes?(stream:)
        @streams.any? { |candidate| candidate.equal?(stream) }
      end

      def attach
        writer = @state.synchronize { @writer.dup unless @writer.closed? }
        unless writer
          # A failure during shutdown must not leave restored regular-file
          # descriptors as an uncapped fallback. A readerless pipe fails closed.
          reader, writer = IO.pipe
          reader.close
        end
        @streams.each_with_index do |stream, index|
          next if stream.closed?

          stream.reopen(writer)
          apply_properties(stream: stream, index: index, captured: true)
        end
      rescue StandardError
        # Construction still has original descriptors available for rollback.
        raise unless @backups.empty?

        # If even dup/reopen fails, close the destinations rather than leave a
        # restored regular-file descriptor able to bypass the retention cap.
        failure = nil
        @streams.each do |stream|
          stream.close unless stream.closed?
        rescue StandardError => e
          failure ||= e
        end
        raise failure if failure

        raise
      ensure
        writer.close if writer && !writer.closed?
      end

      def restore
        file = @state.synchronize do
          prepared = @restore_file
          @restore_file = nil
          prepared
        end
        raise IOError, 'stdio restoration was not prepared' unless file

        @streams.each_with_index do |stream, index|
          next if stream.closed?

          stream.reopen(file)
          apply_properties(stream: stream, index: index, captured: false)
        end
      ensure
        file&.close
      end

      def release_backups
        failure = nil
        @backups.each do |backup|
          backup.close unless backup.closed?
        rescue StandardError => e
          failure ||= e
        end
        @backups.clear
        raise failure if failure
      end

      def rollback
        @streams.each_with_index do |stream, index|
          stream.reopen(@backups[index])
          apply_properties(stream: stream, index: index, captured: false)
        end
      ensure
        begin
          finish!
        ensure
          release_backups
        end
      end

      def check_failure!
        @state.synchronize do
          raise @failure if @failure
          raise IOError, 'stdio capture is stopping' if @stopping
        end
      end

      def flush(deadline:)
        wait_for_flush(deadline: deadline, pause: false)
      end

      def pause(deadline:)
        wait_for_flush(deadline: deadline, pause: true)
      end

      def resume
        file = @state.synchronize do
          @pause_target = nil
          prepared = @restore_file
          @restore_file = nil
          prepared
        end
        file&.close
        @state.synchronize do
          @paused = false
          wake unless @failure || @stopping
        end
      end

      def finish!(deadline: nil) # rubocop:disable Naming/PredicateMethod -- Stops and joins the worker; false signals its deadline.
        @state.synchronize do
          unless @stopping
            @stopping = true
            wake unless @failure
          end
        end
        remaining = [deadline - ::Process.clock_gettime(::Process::CLOCK_MONOTONIC), 0].max if deadline
        !@worker.join(remaining).nil?
      end

      def command(type:, arguments:)
        @state.synchronize do
          raise @failure if @failure
          raise IOError, 'stdio capture is stopping' if @stopping

          wait_until { !@command }

          command = { type: type, arguments: arguments, complete: false }
          @command = command
          wake
          wait_until { command[:complete] }
          command[:result]
        end
      end

      private

      def apply_properties(stream:, index:, captured:)
        sync, close_on_exec, external, internal = @properties[index]
        stream.sync = captured || sync
        stream.close_on_exec = close_on_exec
        stream.set_encoding(external, internal) if external
      end

      def wait_for_flush(deadline:, pause:)
        @state.synchronize do
          raise @failure if @failure
          raise IOError, 'stdio capture is stopping' if @stopping

          target = @requested_flush += 1
          @pause_target = target if pause
          wake
          wait_until(deadline: deadline) { @completed_flush >= target && (!pause || @paused) }
        end
      end

      def wait_until(deadline: nil)
        loop do
          raise @failure if @failure
          return true if yield

          if deadline
            remaining = deadline - ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
            return false unless remaining.positive?
          end

          @changed.wait(@state, remaining)
        end
      end

      def wake
        return if @wake_pending

        @wake_writer.write_nonblock('.')
        @wake_pending = true
      end

      def next_action
        @state.synchronize do
          return [:stop] if @stopping
          return [:wait] if @paused
          return [:command, @command] if @command

          # Only this thread completes flushes, after both the read and its
          # corresponding sink write. A consumed chunk cannot hide from flush.
          bytes = @reader.read_nonblock(READ_BYTES, exception: false)
          return [:write, bytes] if bytes.is_a?(String)
          return [:flush, @requested_flush] if @requested_flush > @completed_flush

          [:wait]
        end
      end

      def drain
        loop do
          action, payload = next_action
          case action
          when :stop then break
          when :wait then wait_for_input
          when :write then @sink.write(payload)
          when :command then execute_command(command: payload)
          when :flush then complete_flush(target: payload)
          end
        end
      rescue StandardError => e
        # Closing the read end wakes blocked producers with EPIPE. Never log a
        # drain failure to stderr: stderr may be the pipe which just failed.
        begin
          @reader.close unless @reader.closed?
        ensure
          @state.synchronize do
            @failure = e
            @changed.broadcast
          end
        end
        raise
      ensure
        close_handles
      end

      def wait_for_input
        IO.select(@paused ? [@wake_reader] : [@reader, @wake_reader])
        @state.synchronize do
          @wake_reader.read_nonblock(READ_BYTES, exception: false)
          @wake_pending = false
        end
      end

      def execute_command(command:)
        result = @sink.public_send(command[:type], **command[:arguments])
        @state.synchronize do
          command[:result] = result
          command[:complete] = true
          @command = nil
          @changed.broadcast
        end
      end

      def complete_flush(target:)
        @sink.flush
        prepare = @state.synchronize { @pause_target && target >= @pause_target }
        file = File.new(@path, 'ab') if prepare
        retained = false
        @state.synchronize do
          @completed_flush = target
          if file && @pause_target && target >= @pause_target
            @restore_file = file
            @paused = true
            retained = true
          end
          @changed.broadcast
        end
      ensure
        file.close if file && !retained
      end

      def close_handles
        failure = nil
        [@reader, @writer, @wake_reader, @wake_writer, @restore_file, @sink].compact.each do |handle|
          if handle.equal?(@writer)
            @state.synchronize { handle.close unless handle.closed? }
          else
            handle.close unless handle.closed?
          end
        rescue StandardError => e
          failure ||= e
          @state.synchronize do
            @failure ||= e
            @changed.broadcast
          end
        end
        raise failure if failure
      end
    end
    private_constant :StdioCapture
  end
end
