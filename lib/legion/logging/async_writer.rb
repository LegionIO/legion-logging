# frozen_string_literal: true

require_relative 'methods'

module Legion
  module Logging
    class AsyncWriter
      LogEntry = ::Data.define(:level, :message, :writer_context, :segments, :method_ctx, :caller_trace)
      SHUTDOWN = :shutdown

      attr_reader :logger

      def initialize(logger, buffer_size: 10_000)
        @logger = logger
        @buffer_size = buffer_size
        @queue  = SizedQueue.new(buffer_size)
        @thread = nil
        @state_mutex = Mutex.new
        @accepting = true
      end

      def start
        return if @thread&.alive?

        @state_mutex.synchronize { @accepting = true }
        drain
        @queue = SizedQueue.new(@buffer_size)
        @thread = Thread.new { consume }
        @thread.name = 'legion-log-writer'
        @thread.abort_on_exception = false
      end

      # rubocop:disable Naming/PredicateMethod
      def stop(timeout: 2)
        @state_mutex.synchronize { @accepting = false }

        unless @thread&.alive?
          drain
          @thread = nil
          return true
        end

        @queue.close
        timeout ? @thread.join(timeout) : @thread.join
        return false if @thread&.alive?

        @thread = nil
        true
      end

      def push(entry)
        return false unless accepting?

        @queue.push(entry)
        true
      rescue ClosedQueueError
        false
      end
      # rubocop:enable Naming/PredicateMethod

      def alive?
        @thread&.alive? || false
      end

      private

      def consume
        loop do
          entry = @queue.pop
          break if entry.nil? || entry == SHUTDOWN

          write_entry(entry)
        end
      end

      def write_entry(entry)
        prev_segments   = Thread.current[:legion_log_segments]
        prev_method_ctx = Thread.current[:legion_log_method]
        prev_caller     = Thread.current[:legion_log_caller]
        Thread.current[:legion_log_segments] = entry.segments
        Thread.current[:legion_log_method]   = entry.method_ctx
        Thread.current[:legion_log_caller]   = entry.caller_trace
        @logger.send(entry.level, entry.message)
        fire_writer(entry) if entry.writer_context
      rescue StandardError => e
        warn("legion-log-writer error: #{e.message} (#{e.backtrace&.first})")
      ensure
        Thread.current[:legion_log_segments] = prev_segments
        Thread.current[:legion_log_method]   = prev_method_ctx
        Thread.current[:legion_log_caller]   = prev_caller
      end

      def drain
        until @queue.empty?
          entry = @queue.pop(true)
          write_entry(entry) unless entry == SHUTDOWN
        end
      rescue ThreadError
        nil
      end

      def accepting?
        @state_mutex.synchronize { @accepting }
      end

      def fire_writer(entry)
        ctx = entry.writer_context
        event = ctx[:event]
        level = ctx[:level]
        lex_name = event[:lex] || 'core'
        component = event.dig(:caller, :file).to_s[Legion::Logging::Methods::COMPONENT_REGEX, 1] || 'unknown'
        routing_key = "legion.logging.log.#{level}.#{lex_name}.#{component}"
        Legion::Logging.log_writer.call(event, routing_key: routing_key)
        Legion::Logging::Hooks.fire(level, entry.message, event) if defined?(Legion::Logging::Hooks)
      rescue StandardError => e
        warn("legion-log-writer writer error: #{e.message}")
      end
    end
  end
end
