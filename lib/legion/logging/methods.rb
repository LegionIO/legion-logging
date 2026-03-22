# frozen_string_literal: true

module Legion
  module Logging
    module Methods
      def trace(raw_message = nil, size: @trace_size, log_caller: true)
        return unless @trace_enabled

        raw_message = yield if raw_message.nil? && block_given?
        message = Rainbow('Tracing: ').cyan
        message.concat Rainbow("#{raw_message} ").cyan
        if log_caller && size.nil?
          message.concat Rainbow(caller_locations).cyan.underline
        elsif log_caller
          message.concat Rainbow(caller_locations[0..size]).cyan.underline
        end
        log.unknown(message)
      end

      def debug(message = nil)
        return unless log.level < 1

        message = yield if message.nil? && block_given?
        message = Rainbow(message).blue if @color
        log.debug(message)
      end

      def info(message = nil)
        return unless log.level < 2

        message = yield if message.nil? && block_given?
        message = Rainbow(message).green if @color
        log.info(message)
      end

      def warn(message = nil)
        return unless log.level < 3

        message = yield if message.nil? && block_given?
        raw = message
        message = Rainbow(message).yellow if @color
        log.warn(message)
        fire_hooks(:warn, raw)
      end

      def error(message = nil)
        return unless log.level < 4

        message = yield if message.nil? && block_given?
        raw = message
        message = Rainbow(message).red if @color
        log.error(message)
        fire_hooks(:error, raw)
      end

      def fatal(message = nil)
        return unless log.level < 5

        message = yield if message.nil? && block_given?
        raw = message
        message = Rainbow(message).darkred if @color
        log.fatal(message)
        fire_hooks(:fatal, raw)
      end

      def unknown(message = nil)
        message = yield if message.nil? && block_given?
        message = Rainbow(message).purple if @color
        log.unknown(message)
      end

      def runner_exception(exc, **opts)
        Legion::Logging.error exc.message
        Legion::Logging.error exc.backtrace
        Legion::Logging.error opts
        { success: false, message: exc.message, backtrace: exc.backtrace }.merge(opts)
      end

      def thread(kvl: false, **_opts)
        if kvl
          "thread=#{Thread.current.object_id}"
        else
          Thread.current.object_id.to_s
        end
      end

      private

      def fire_hooks(level, message)
        return unless Legion::Logging::Hooks.enabled?
        return if Legion::Logging::Hooks.hooks[level].empty?

        lex_val  = instance_variable_defined?(:@lex) ? @lex : nil
        lex_segs = instance_variable_defined?(:@lex_segments) ? @lex_segments : nil

        event = Legion::Logging::EventBuilder.build(
          level:         level,
          message:       message,
          lex:           lex_val,
          lex_segments:  lex_segs,
          caller_offset: 4
        )
        Legion::Logging::Hooks.fire(level, event)
      end
    end
  end
end
