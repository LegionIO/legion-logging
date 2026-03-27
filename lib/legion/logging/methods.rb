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
        message = maybe_redact(message)
        message = Rainbow(message).blue if @color
        writer = @async_writer
        if writer&.alive?
          writer.push(AsyncWriter::LogEntry.new(level: :debug, message: message, writer_context: nil))
        else
          log.debug(message)
        end
      end

      def info(message = nil)
        return unless log.level < 2

        message = yield if message.nil? && block_given?
        message = maybe_redact(message)
        message = Rainbow(message).green if @color
        writer = @async_writer
        if writer&.alive?
          writer.push(AsyncWriter::LogEntry.new(level: :info, message: message, writer_context: nil))
        else
          log.info(message)
        end
      end

      def warn(message = nil)
        return unless log.level < 3

        message = yield if message.nil? && block_given?
        message = maybe_redact(message)
        raw = message
        message = Rainbow(message).yellow if @color
        writer = @async_writer
        if writer&.alive?
          ctx = build_writer_context(:warn, raw)
          writer.push(AsyncWriter::LogEntry.new(level: :warn, message: message, writer_context: ctx))
        else
          log.warn(message)
          fire_log_writer(:warn, raw)
        end
      end

      def error(message = nil)
        return unless log.level < 4

        message = yield if message.nil? && block_given?
        message = maybe_redact(message)
        raw = message
        message = Rainbow(message).red if @color
        writer = @async_writer
        if writer&.alive?
          ctx = build_writer_context(:error, raw)
          writer.push(AsyncWriter::LogEntry.new(level: :error, message: message, writer_context: ctx))
        else
          log.error(message)
          fire_log_writer(:error, raw)
        end
      end

      def fatal(message = nil)
        return unless log.level < 5

        message = yield if message.nil? && block_given?
        message = maybe_redact(message)
        raw = message
        message = Rainbow(message).darkred if @color
        log.fatal(message)
        fire_log_writer(:fatal, raw)
      end

      def unknown(message = nil)
        message = yield if message.nil? && block_given?
        message = maybe_redact(message)
        message = Rainbow(message).purple if @color
        writer = @async_writer
        if writer&.alive?
          writer.push(AsyncWriter::LogEntry.new(level: :unknown, message: message, writer_context: nil))
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

      def maybe_redact(message)
        return message unless message.is_a?(String)
        return message unless redaction_enabled?
        return message unless defined?(Legion::Logging::Redactor)

        Legion::Logging::Redactor.redact_string(message)
      rescue StandardError
        message
      end

      def redaction_enabled?
        return false unless defined?(Legion::Settings)

        loader = Legion::Settings.instance_variable_get(:@loader)
        return false unless loader

        loader.dig(:logging, :redaction, :enabled) == true
      rescue StandardError
        false
      end

      def build_writer_context(level, message)
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

      def fire_log_writer(level, message)
        lex_val  = instance_variable_defined?(:@lex) ? @lex : nil
        lex_segs = instance_variable_defined?(:@lex_segments) ? @lex_segments : nil

        event = Legion::Logging::EventBuilder.build(
          level:         level,
          message:       message,
          lex:           lex_val,
          lex_segments:  lex_segs,
          caller_offset: 4
        )
        lex_name = event[:lex] || 'core'
        component = event.dig(:caller, :file).to_s[%r{/(runners|actors|transport|helpers|builders)/}, 1] || 'unknown'
        routing_key = "legion.logging.log.#{level}.#{lex_name}.#{component}"
        Legion::Logging.log_writer.call(event, routing_key: routing_key)
      rescue StandardError
        nil
      end
    end
  end
end
