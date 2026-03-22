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
        writer = @async_writer
        if writer&.alive?
          writer.push(AsyncWriter::LogEntry.new(level: :debug, message: message, hook_context: nil))
        else
          log.debug(message)
        end
      end

      def info(message = nil)
        return unless log.level < 2

        message = yield if message.nil? && block_given?
        message = Rainbow(message).green if @color
        writer = @async_writer
        if writer&.alive?
          writer.push(AsyncWriter::LogEntry.new(level: :info, message: message, hook_context: nil))
        else
          log.info(message)
        end
      end

      def warn(message = nil)
        return unless log.level < 3

        message = yield if message.nil? && block_given?
        raw = message
        message = Rainbow(message).yellow if @color
        writer = @async_writer
        if writer&.alive?
          ctx = build_hook_context(:warn, raw)
          writer.push(AsyncWriter::LogEntry.new(level: :warn, message: message, hook_context: ctx))
        else
          log.warn(message)
          fire_hooks(:warn, raw)
        end
      end

      def error(message = nil)
        return unless log.level < 4

        message = yield if message.nil? && block_given?
        raw = message
        message = Rainbow(message).red if @color
        writer = @async_writer
        if writer&.alive?
          ctx = build_hook_context(:error, raw)
          writer.push(AsyncWriter::LogEntry.new(level: :error, message: message, hook_context: ctx))
        else
          log.error(message)
          fire_hooks(:error, raw)
        end
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
        writer = @async_writer
        if writer&.alive?
          writer.push(AsyncWriter::LogEntry.new(level: :unknown, message: message, hook_context: nil))
        else
          log.unknown(message)
        end
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

      def build_hook_context(level, message)
        return nil unless Legion::Logging::Hooks.enabled?
        return nil if Legion::Logging::Hooks.hooks[level].empty?

        lex_val  = instance_variable_defined?(:@lex) ? @lex : nil
        lex_segs = instance_variable_defined?(:@lex_segments) ? @lex_segments : nil

        event = Legion::Logging::EventBuilder.build(
          level:         level,
          message:       message,
          lex:           lex_val,
          lex_segments:  lex_segs,
          caller_offset: 4
        )
        { level: level, event: event }
      end

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
