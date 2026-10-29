# frozen_string_literal: true

require 'logger'

module Legion
  module Logging
    # Keeps the standard Logger interface used by Sinatra/APM on the async queue.
    class OutputLogger < ::Logger
      attr_accessor :async_writer

      def add(severity, message = nil, progname = nil)
        writer = @async_writer
        return super unless writer && !writer.current_thread?

        severity ||= UNKNOWN
        return true if @logdev.nil? || severity < level

        progname ||= @progname
        if message.nil?
          if block_given?
            message = yield
          else
            message = progname
            progname = @progname
          end
        end
        enqueue_output(severity: severity, message: message, progname: progname)
      end
      alias log add

      def <<(message)
        writer = @async_writer
        return super unless writer && !writer.current_thread?

        enqueue_output(severity: nil, message: message, progname: nil)
      end

      private

      def enqueue_output(severity:, message:, progname:) # rubocop:disable Naming/PredicateMethod
        entry = Legion::Logging::AsyncWriter::OutputEntry.new(
          severity:     severity,
          message:      Legion::Logging::AsyncWriter.snapshot_value(value: message),
          progname:     Legion::Logging::AsyncWriter.snapshot_value(value: progname),
          segments:     Legion::Logging::AsyncWriter.snapshot_value(value: Thread.current[:legion_log_segments]),
          method_ctx:   Legion::Logging::AsyncWriter.snapshot_value(value: Thread.current[:legion_log_method]),
          caller_trace: Legion::Logging::AsyncWriter.snapshot_value(value: Thread.current[:legion_log_caller]),
          conv_id:      Legion::Logging::AsyncWriter.snapshot_value(value: Thread.current[:legion_log_conv_id]),
          request_id:   Legion::Logging::AsyncWriter.snapshot_value(value: Thread.current[:legion_log_request_id]),
          exchange_id:  Legion::Logging::AsyncWriter.snapshot_value(value: Thread.current[:legion_log_exchange_id]),
          chain_id:     Legion::Logging::AsyncWriter.snapshot_value(value: Thread.current[:legion_log_chain_id]),
          origin:       { timestamp: Time.now.utc, thread: Thread.current.object_id }
        )
        raise ClosedQueueError, 'async logging writer is unavailable' unless @async_writer.alive? && @async_writer.push(entry)

        true
      end
    end
  end
end
