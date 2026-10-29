# frozen_string_literal: true

require 'json'
require_relative 'methods'

module Legion
  module Logging
    class AsyncWriter
      LogEntry = ::Data.define(:level, :message, :writer_context, :segments, :method_ctx, :caller_trace,
                               :conv_id, :request_id, :exchange_id, :chain_id, :force)
      EventEntry = ::Data.define(:callback, :event, :options)
      CallEntry = ::Data.define(:receiver, :method_name, :arguments, :keywords, :context)
      OutputEntry = ::Data.define(:severity, :message, :progname, :segments, :method_ctx, :caller_trace,
                                  :conv_id, :request_id, :exchange_id, :chain_id)
      THREAD_KEYS = %i[
        legion_log_segments legion_log_method legion_log_caller
        legion_log_conv_id legion_log_request_id legion_log_exchange_id legion_log_chain_id
      ].freeze
      CALL_THREAD_KEYS = (THREAD_KEYS + %i[legion_context legion_session_context legion_log_origin]).freeze

      attr_reader :logger

      def initialize(logger, buffer_size: 10_000)
        @logger = logger
        @buffer_size = buffer_size
        @queue  = SizedQueue.new(buffer_size)
        @thread = nil
        @state_mutex = Mutex.new
        @accepting = true
      end

      # rubocop:disable Naming/PredicateMethod
      def start
        @state_mutex.synchronize do
          return @accepting if @thread&.alive?

          if @queue.closed?
            queue = SizedQueue.new(@buffer_size)
            queue << @queue.pop(true) until @queue.empty?
            @queue = queue
          end
          @accepting = true
          @thread = Thread.new { consume(queue: @state_mutex.synchronize { @queue }) }
          @thread.name = 'legion-log-writer'
          @thread.abort_on_exception = false
        end
        true
      end

      def stop(timeout: 2)
        deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + timeout if timeout
        thread = @state_mutex.synchronize do
          @accepting = false
          @queue.close
          if !@thread&.alive? && !@queue.empty?
            @thread = Thread.new { consume(queue: @state_mutex.synchronize { @queue }) }
            @thread.name = 'legion-log-writer'
            @thread.abort_on_exception = false
          end
          @thread
        end
        return true unless thread
        return false if Thread.current.equal?(thread)

        remaining = [deadline - ::Process.clock_gettime(::Process::CLOCK_MONOTONIC), 0].max if deadline
        thread.join(remaining)
        return false if thread.alive?

        @state_mutex.synchronize { @thread = nil if @thread.equal?(thread) }
        true
      end

      def push(entry)
        if current_thread?
          return write_reentrant_entry(entry) unless @preparing

          write_entry(entry)
          return true
        end

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

      def current_thread?
        Thread.current.equal?(@thread)
      end

      private

      def consume(queue:)
        loop do
          entry = queue.pop
          break if entry.nil?

          write_entry(entry)
        end
      end

      def write_entry(entry, forward: true)
        previous_preparing = @preparing
        @preparing = entry.is_a?(CallEntry)
        if @preparing
          write_call_entry(entry)
          return
        end

        if entry.is_a?(EventEntry)
          callback_origin = Thread.current[:legion_log_origin]
          Thread.current[:legion_log_origin] = nil
          entry.callback.call(entry.event, **entry.options)
          return
        end

        with_entry_context(entry) do
          if entry.is_a?(OutputEntry)
            entry.severity.nil? ? @logger << entry.message : @logger.add(entry.severity, entry.message, entry.progname)
          else
            if entry.force
              formatter = @logger.formatter || ::Logger::Formatter.new
              severity = entry.level == :unknown ? 'ANY' : entry.level.to_s.upcase
              @logger << formatter.call(severity, Time.now, nil, entry.message)
            else
              @logger.send(entry.level, entry.message)
            end
            fire_writer(entry) if forward && entry.writer_context
          end
        end
      rescue StandardError => e
        warn("legion-log-writer error: #{e.message} (#{e.backtrace&.first})")
      ensure
        @preparing = previous_preparing
        Thread.current[:legion_log_origin] = callback_origin if entry.is_a?(EventEntry)
      end

      def write_reentrant_entry(entry)
        previous = @reentrant_write
        @reentrant_write = true
        if previous || entry.is_a?(EventEntry)
          event = entry.is_a?(EventEntry) ? entry.event : { message: entry.message.to_s }
          @logger << "#{::JSON.generate(event)}\n"
        else
          write_entry(entry, forward: false)
        end
        true
      ensure
        @reentrant_write = previous
      end

      def write_call_entry(entry)
        previous = entry.context.map { |key, _| [key, Thread.current[key]] }
        entry.context.each { |key, value| Thread.current[key] = value }
        entry.receiver.public_send(entry.method_name, *entry.arguments, **entry.keywords)
      ensure
        previous&.each { |key, value| Thread.current[key] = value }
      end

      def with_entry_context(entry)
        prev = THREAD_KEYS.map { |k| [k, Thread.current[k]] }
        Thread.current[:legion_log_segments]    = entry.segments
        Thread.current[:legion_log_method]      = entry.method_ctx
        Thread.current[:legion_log_caller]      = entry.caller_trace
        Thread.current[:legion_log_conv_id]     = entry.conv_id
        Thread.current[:legion_log_request_id]  = entry.request_id
        Thread.current[:legion_log_exchange_id] = entry.exchange_id
        Thread.current[:legion_log_chain_id]    = entry.chain_id
        yield
      ensure
        prev&.each { |k, v| Thread.current[k] = v }
      end

      def accepting?
        @state_mutex.synchronize { @accepting }
      end

      def fire_writer(entry)
        previous_origin = Thread.current[:legion_log_origin]
        ctx = entry.writer_context
        event = ctx[:event]
        level = ctx[:level]
        lex_name = event[:lex] || 'core'
        component = event.dig(:caller, :file).to_s[Legion::Logging::Methods::COMPONENT_REGEX, 1] || 'unknown'
        routing_key = "legion.logging.log.#{level}.#{lex_name}.#{component}"
        headers    = Legion::Logging.send(:build_log_headers, event, component, level)
        properties = Legion::Logging.send(:build_log_properties, level)
        Thread.current[:legion_log_origin] = nil
        Legion::Logging.log_writer.call(event, routing_key: routing_key, headers: headers, properties: properties)
        Legion::Logging::Hooks.fire(level, entry.message, event) if defined?(Legion::Logging::Hooks)
      rescue StandardError => e
        warn("legion-log-writer writer error: #{e.message}")
      ensure
        Thread.current[:legion_log_origin] = previous_origin
      end
    end
  end
end
