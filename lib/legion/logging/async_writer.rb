# frozen_string_literal: true

require_relative 'methods'

module Legion
  module Logging
    class AsyncWriter
      LogEntry = ::Data.define(:level, :message, :writer_context, :segments, :method_ctx)
      SHUTDOWN = :shutdown

      def initialize(logger, buffer_size: 10_000)
        @logger = logger
        @queue  = SizedQueue.new(buffer_size)
        @thread = nil
      end

      def start
        return if @thread&.alive?

        drain
        @thread = Thread.new { consume }
        @thread.name = 'legion-log-writer'
        @thread.abort_on_exception = false
      end

      def stop(timeout: 2)
        return unless @thread&.alive?

        begin
          @queue.push(SHUTDOWN, true)
        rescue ThreadError
          # Queue full — fall through to join/kill + drain
        end
        @thread.join(timeout)
        @thread.kill if @thread&.alive?
        drain
      end

      def push(entry)
        @queue.push(entry)
      end

      def alive?
        @thread&.alive? || false
      end

      private

      def consume
        loop do
          entry = @queue.pop
          break if entry == SHUTDOWN

          write_entry(entry)
        end
      end

      def write_entry(entry)
        prev_segments   = Thread.current[:legion_log_segments]
        prev_method_ctx = Thread.current[:legion_log_method]
        Thread.current[:legion_log_segments] = entry.segments   if entry.segments
        Thread.current[:legion_log_method]   = entry.method_ctx if entry.method_ctx
        @logger.send(entry.level, entry.message)
        fire_writer(entry) if entry.writer_context
      rescue StandardError => e
        warn("legion-log-writer error: #{e.message} (#{e.backtrace&.first})")
      ensure
        Thread.current[:legion_log_segments] = prev_segments
        Thread.current[:legion_log_method]   = prev_method_ctx
      end

      def drain
        until @queue.empty?
          entry = @queue.pop(true)
          write_entry(entry) unless entry == SHUTDOWN
        end
      rescue ThreadError
        nil
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
