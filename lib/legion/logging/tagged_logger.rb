# frozen_string_literal: true

module Legion
  module Logging
    class TaggedLogger
      LEVELS = { debug: 0, info: 1, warn: 2, error: 3, fatal: 4, unknown: 5 }.freeze

      attr_reader :segments, :trace_enabled, :extended

      def initialize(segments:, level: :info, trace: false, trace_size: 4, extended: false, **_opts)
        @segments = segments
        @level_value = LEVELS.fetch(level.to_s.downcase.to_sym, 1)
        @trace_enabled = trace
        @trace_size = trace_size
        @extended = extended
      end

      def level
        @level_value
      end

      def debug(message = nil)
        return unless @level_value < 1

        message = yield if message.nil? && block_given?
        with_segments { Legion::Logging.debug(message) }
      end

      def info(message = nil)
        return unless @level_value < 2

        message = yield if message.nil? && block_given?
        with_segments { Legion::Logging.info(message) }
      end

      def warn(message = nil)
        return unless @level_value < 3

        message = yield if message.nil? && block_given?
        with_segments { Legion::Logging.warn(message) }
      end

      def error(message = nil)
        return unless @level_value < 4

        message = yield if message.nil? && block_given?
        with_segments { Legion::Logging.error(message) }
      end

      def fatal(message = nil)
        return unless @level_value < 5

        message = yield if message.nil? && block_given?
        with_segments { Legion::Logging.fatal(message) }
      end

      def unknown(message = nil)
        message = yield if message.nil? && block_given?
        with_segments { Legion::Logging.unknown(message) }
      end

      def trace(raw_message = nil, size: @trace_size, log_caller: true)
        return unless @trace_enabled

        raw_message = yield if raw_message.nil? && block_given?
        message = "Tracing: #{raw_message} "
        if log_caller
          frames = size ? caller_locations(1, size) : caller_locations(1)
          message.concat(frames&.join(', ').to_s)
        end
        with_segments { Legion::Logging.unknown(message) }
      end

      def thread(kvl: false, **_opts)
        if kvl
          "thread=#{Thread.current.object_id}"
        else
          Thread.current.object_id.to_s
        end
      end

      private

      def with_segments
        prev = Thread.current[:legion_log_segments]
        Thread.current[:legion_log_segments] = @segments
        yield
      ensure
        Thread.current[:legion_log_segments] = prev
      end
    end
  end
end
