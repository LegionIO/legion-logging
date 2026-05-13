# frozen_string_literal: true

require 'securerandom'

module Legion
  module Logging
    module Methods
      COMPONENT_REGEX = %r{
        /(runners|actors|actor|helpers|hooks|absorbers|matchers|transport|
        exchanges|queues|messages|data|builders|tools|adapters|engines|
        formatters|parsers|middleware)/
      }x
      EXCEPTION_PRIORITY = { warn: 0, error: 5, fatal: 9 }.freeze

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
        raw = maybe_redact(message)
        formatted = format_message_for_level(:debug, raw)
        write_async_or_sync(:debug, formatted, raw)
      end

      def info(message = nil)
        return unless log.level < 2

        message = yield if message.nil? && block_given?
        raw = maybe_redact(message)
        formatted = format_message_for_level(:info, raw)
        write_async_or_sync(:info, formatted, raw)
      end

      def warn(message = nil)
        return unless log.level < 3

        message = yield if message.nil? && block_given?
        raw = maybe_redact(message)
        formatted = format_message_for_level(:warn, raw)
        write_async_or_sync(:warn, formatted, raw, writer_context: build_writer_context(:warn, raw))
      end

      def error(message = nil)
        return unless log.level < 4

        message = yield if message.nil? && block_given?
        raw = maybe_redact(message)
        formatted = format_message_for_level(:error, raw)
        write_async_or_sync(:error, formatted, raw, writer_context: build_writer_context(:error, raw))
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
        raw = maybe_redact(message)
        formatted = format_message_for_level(:unknown, raw)
        write_async_or_sync(:unknown, formatted, raw)
      end

      def emit_tagged(level, message = nil, segments: nil, method_ctx: nil)
        level = level.to_sym
        message = yield if message.nil? && block_given?
        return if message.nil?

        raw = maybe_redact(message)
        formatted = format_message_for_level(level, raw)

        with_tagged_context(segments, method_ctx) do
          write_forced(level, formatted)
          fire_log_writer(level, raw) if %i[warn error fatal].include?(level)
        end
      end

      def runner_exception(exc, **opts)
        log_exception(exc, handled: true, **opts)
        { success: false, message: exc.message, backtrace: exc.backtrace }.merge(opts)
      end

      def log_exception(exception, level: :error, lex: nil, component_type: nil,
                        gem_name: nil, lex_version: nil, gem_path: nil,
                        source_code_uri: nil, handled: false, payload_summary: nil,
                        task_id: nil, backtrace_limit: nil, **extra)
        level = level.to_sym if level.respond_to?(:to_sym)
        # 1. Log human-readable line + backtrace to stdout/file (bypass writer callbacks)
        msg = exception.respond_to?(:message) ? exception.message : exception.to_s
        msg = maybe_redact(msg)
        msg = build_exception_log_message(exception, msg, backtrace_limit)
        log.public_send(level, msg) if respond_to?(:log) && log.respond_to?(level)

        # 2. Build rich exception event
        event = Legion::Logging::EventBuilder.build_exception(
          exception:       exception,
          level:           level,
          lex:             lex,
          component_type:  component_type,
          gem_name:        gem_name,
          lex_version:     lex_version,
          gem_path:        gem_path,
          source_code_uri: source_code_uri,
          handled:         handled,
          payload_summary: payload_summary,
          task_id:         task_id,
          caller_offset:   3,
          **extra
        )

        # 3. Redact secrets before publishing
        event = Legion::Logging::Redactor.redact(event) if defined?(Legion::Logging::Redactor)

        # 4. Publish rich event via exception_writer
        publish_exception_event(event, level)
      rescue StandardError => e
        if respond_to?(:log) && log.respond_to?(:warn)
          log.warn("Failed to publish structured exception event: #{e.class}: #{e.message}")
        else
          warn("Failed to publish structured exception event: #{e.class}: #{e.message}")
        end
      end

      def thread(kvl: false, **_opts)
        if kvl
          "thread=#{Thread.current.object_id}"
        else
          Thread.current.object_id.to_s
        end
      end

      private

      def resolve_backtrace_limit(explicit_limit)
        return explicit_limit unless explicit_limit.nil?
        return nil unless defined?(Legion::Settings)

        Legion::Settings[:logging][:backtrace_limit]
      end

      def build_exception_log_message(exception, msg, backtrace_limit)
        max_frames = resolve_backtrace_limit(backtrace_limit)
        bt = collect_backtrace_frames(exception, max_frames)
        return msg unless bt.any?

        lines = ["#{exception.class}: #{msg}"]
        bt.each { |frame| lines << "  #{frame}" }
        lines.join("\n")
      end

      def collect_backtrace_frames(exception, max_frames)
        return [] if max_frames&.zero?

        frames = Array(exception.backtrace)
        max_frames ? frames.first(max_frames) : frames
      end

      def maybe_redact(message)
        return message unless message.is_a?(String)
        return message unless redaction_enabled?
        return message unless defined?(Legion::Logging::Redactor)

        Legion::Logging::Redactor.redact_string(message)
      rescue StandardError
        message
      end

      def format_message_for_level(level, message)
        return Rainbow(message).blue if level == :debug && @color
        return Rainbow(message).green if level == :info && @color
        return Rainbow(message).yellow if level == :warn && @color
        return Rainbow(message).red if level == :error && @color
        return Rainbow(message).darkred if level == :fatal && @color
        return Rainbow(message).purple if level == :unknown && @color

        message
      end

      def with_tagged_context(segments, method_ctx)
        prev_segments = Thread.current[:legion_log_segments]
        prev_method_ctx = Thread.current[:legion_log_method]

        Thread.current[:legion_log_segments] = segments unless segments.nil?
        Thread.current[:legion_log_method] = method_ctx unless method_ctx.nil?
        yield
      ensure
        Thread.current[:legion_log_segments] = prev_segments
        Thread.current[:legion_log_method] = prev_method_ctx
      end

      def write_forced(level, message)
        logger = log
        formatter = logger.formatter || ::Logger::Formatter.new
        rendered = formatter.call(severity_label_for(level), Time.now, nil, message)

        log_device = logger.instance_variable_get(:@logdev)
        if log_device.respond_to?(:write)
          log_device.write(rendered)
        else
          $stdout.write(rendered)
        end
      end

      def severity_label_for(level)
        return 'ANY' if level == :unknown

        level.to_s.upcase
      end

      def write_async_or_sync(level, formatted_message, raw_message, writer_context: nil)
        writer = @async_writer
        caller_trace = capture_runner_trace_for_async
        if writer&.alive?
          queued = writer.push(AsyncWriter::LogEntry.new(
                                 level:          level,
                                 message:        formatted_message,
                                 writer_context: writer_context,
                                 segments:       Thread.current[:legion_log_segments],
                                 method_ctx:     Thread.current[:legion_log_method],
                                 caller_trace:   caller_trace
                               ))
          return if queued
        end

        with_caller_trace(caller_trace) do
          log.public_send(level, formatted_message)
          fire_log_writer(level, raw_message) if writer_context
        end
      end

      def capture_runner_trace_for_async
        build_runner_trace(caller_locations(4, 1)&.first)
      end

      def with_caller_trace(caller_trace)
        prev_caller_trace = Thread.current[:legion_log_caller]
        Thread.current[:legion_log_caller] = caller_trace
        yield
      ensure
        Thread.current[:legion_log_caller] = prev_caller_trace
      end

      def redaction_enabled?
        return false unless defined?(Legion::Settings)

        loader = Legion::Settings.instance_variable_get(:@loader)
        return false unless loader

        loader.dig(:logging, :redaction, :enabled) == true
      rescue StandardError
        false
      end

      def publish_exception_event(event, level)
        lex_name = event[:lex] || 'core'
        comp     = event[:component_type] || :unknown
        routing_key = "legion.logging.exception.#{level}.#{lex_name}.#{comp}"
        headers     = build_exception_headers(event, comp, level)
        properties  = build_exception_properties(event, level)
        Legion::Logging.exception_writer.call(event, routing_key: routing_key, headers: headers, properties: properties)
      end

      def build_exception_headers(event, comp, level)
        headers = {
          'x-error-fingerprint' => event[:error_fingerprint],
          'x-exception-class'   => event[:exception_class],
          'x-handled'           => event[:handled].to_s,
          'x-gem-name'          => event[:gem_name].to_s,
          'x-lex-version'       => event[:lex_version].to_s,
          'x-component-type'    => comp.to_s,
          'x-level'             => level.to_s
        }
        append_optional_header(headers, 'x-task-id', event[:task_id])
        append_optional_header(headers, 'x-conversation-id', event[:conversation_id])
        append_optional_header(headers, 'x-user', event[:user])
        headers
      end

      def append_optional_header(headers, key, value)
        return if value.nil?
        return if value.respond_to?(:empty?) && value.empty?

        headers[key] = value.to_s
      end

      def build_exception_properties(event, level)
        {
          content_type:   'application/json',
          message_id:     SecureRandom.uuid,
          correlation_id: event[:error_fingerprint],
          timestamp:      Time.now.to_i,
          app_id:         'legionio',
          type:           'exception_event',
          priority:       EXCEPTION_PRIORITY[level] || 5,
          delivery_mode:  2
        }
      end

      def build_writer_context(level, message)
        has_writer = !Legion::Logging.instance_variable_get(:@log_writer).nil?
        has_hooks = defined?(Legion::Logging::Hooks) && Legion::Logging::Hooks.enabled?
        return nil unless has_writer || has_hooks

        lex_val  = instance_variable_defined?(:@lex) ? @lex : nil
        lex_segs = Thread.current[:legion_log_segments] || (instance_variable_defined?(:@lex_segments) ? @lex_segments : nil)

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
        lex_segs = Thread.current[:legion_log_segments] || (instance_variable_defined?(:@lex_segments) ? @lex_segments : nil)

        event = Legion::Logging::EventBuilder.build(
          level:         level,
          message:       message,
          lex:           lex_val,
          lex_segments:  lex_segs,
          caller_offset: 4
        )
        lex_name = event[:lex] || 'core'
        component = event.dig(:caller, :file).to_s[COMPONENT_REGEX, 1] || 'unknown'
        routing_key = "legion.logging.log.#{level}.#{lex_name}.#{component}"
        Legion::Logging.log_writer.call(event, routing_key: routing_key)
        Legion::Logging::Hooks.fire(level, message, event) if defined?(Legion::Logging::Hooks)
      rescue StandardError => e
        rk = defined?(routing_key) ? routing_key : 'unknown'
        log.warn("fire_log_writer failed for level=#{level}, routing_key=#{rk}: #{e.class}: #{e.message}") if respond_to?(:log) && log.respond_to?(:warn)
      end
    end
  end
end
