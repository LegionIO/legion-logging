# frozen_string_literal: true

require 'securerandom'
require_relative 'tagged_logger'

module Legion
  module Logging
    module Helper
      SEGMENT_CACHE = {} # rubocop:disable Style/MutableConstant
      SEGMENT_CACHE_MUTEX = Mutex.new
      private_constant :SEGMENT_CACHE_MUTEX
      COMPONENT_MAP = {
        'runners'    => :runner,
        'actors'     => :actor,
        'actor'      => :actor,
        'helpers'    => :helper,
        'hooks'      => :hook,
        'absorbers'  => :absorber,
        'matchers'   => :matcher,
        'transport'  => :transport,
        'exchanges'  => :exchange,
        'queues'     => :queue,
        'messages'   => :message,
        'data'       => :data,
        'builders'   => :builder,
        'tools'      => :tool,
        'adapters'   => :adapter,
        'engines'    => :engine,
        'formatters' => :formatter,
        'parsers'    => :parser,
        'middleware' => :middleware
      }.freeze

      EXCEPTION_BACKTRACE_LIMIT = 10
      EXCEPTION_PRIORITY = { warn: 0, error: 5, fatal: 9 }.freeze
      EXCEPTION_COLORS = {
        fatal:   :darkred,
        error:   :red,
        warn:    :yellow,
        debug:   :aqua,
        unknown: :magenta
      }.freeze

      def self.current_log_method
        Thread.current[:legion_log_method]
      end

      def self.current_log_segments
        Thread.current[:legion_log_segments]
      end

      def self.current_context
        Thread.current[:legion_context]
      end

      def log
        @log ||= Legion::Logging::TaggedLogger.new(segments: derive_log_segments, **settings[:logger])
      end

      def with_log_context(method_name)
        prev = Thread.current[:legion_log_method]
        Thread.current[:legion_log_method] = method_name.to_s
        yield
      ensure
        Thread.current[:legion_log_method] = prev
      end

      def handle_exception(exception, task_id: nil, level: :error, handled: true, **opts)
        segments = derive_log_segments
        spec = gem_spec
        ctx = Thread.current[:legion_context] || {}

        event = Legion::Logging::EventBuilder.build_exception(
          exception:       exception,
          level:           level,
          lex:             log_name,
          component_type:  derive_component_type,
          gem_name:        gem_name,
          lex_version:     spec&.version&.to_s,
          gem_path:        spec&.full_gem_path,
          source_code_uri: spec&.metadata&.[]('source_code_uri'),
          handled:         handled,
          task_id:         task_id || ctx[:task_id],
          payload_summary: opts.empty? ? nil : opts,
          caller_offset:   3
        )

        event[:conversation_id] ||= ctx[:conversation_id]
        event[:chain_id] ||= ctx[:chain_id]
        event[:log_segments] = segments
        event[:method] = Thread.current[:legion_log_method]

        event = Legion::Logging::Redactor.redact(event) if defined?(Legion::Logging::Redactor)

        write_exception_to_log(exception, event, level, segments)
        publish_exception(event, level)
      end

      private

      def derive_log_segments
        key = respond_to?(:ancestors) ? ancestors.first : self.class
        return SEGMENT_CACHE[key] if SEGMENT_CACHE.key?(key)

        segments = begin
          parts = key.to_s.split('::')
          parts.shift if parts.first == 'Legion'
          parts.shift if parts.first == 'Extensions'
          parts.map! do |p|
            p.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
             .gsub(/([a-z\d])([A-Z])/, '\1_\2')
             .downcase
          end
          parts.freeze
        end

        SEGMENT_CACHE_MUTEX.synchronize { SEGMENT_CACHE[key] ||= segments }
      end

      def derive_component_type
        segments = derive_log_segments
        match = segments.find { |s| COMPONENT_MAP.key?(s) }
        return COMPONENT_MAP[match] if match

        segments.last&.to_sym || :unknown
      end

      def log_name
        if respond_to?(:lex_filename)
          fname = lex_filename
          return fname.is_a?(Array) ? fname.first : fname
        end

        derive_log_segments.first
      rescue StandardError
        nil
      end

      def gem_name
        @gem_name_resolved ? @gem_name_value : resolve_gem_name
      end

      def gem_spec
        @gem_spec_resolved ? @gem_spec_value : resolve_gem_spec
      end

      def resolve_gem_name
        @gem_name_resolved = true
        base = log_name
        @gem_name_value = if base
                            %W[lex-#{base} legion-#{base} #{base}].find do |candidate|
                              Gem::Specification.find_by_name(candidate)
                              candidate
                            rescue Gem::MissingSpecError
                              nil
                            end
                          end
      rescue StandardError
        @gem_name_value = nil
      end

      def resolve_gem_spec
        @gem_spec_resolved = true
        name = gem_name
        @gem_spec_value = name ? Gem::Specification.find_by_name(name) : nil
      rescue Gem::MissingSpecError
        @gem_spec_value = nil
      end

      def settings
        { logger: logger_settings }
      end

      def logger_settings
        return Legion::Settings[:logging] if defined?(Legion::Settings) && Legion::Settings[:logging].is_a?(Hash)

        Legion::Logging::Settings.default
      end

      # -- Exception stdout/file output --

      def write_exception_to_log(exception, event, level, segments)
        prev_segs = Thread.current[:legion_log_segments]
        Thread.current[:legion_log_segments] = segments

        message = format_exception_output(exception, event)
        message = Legion::Logging::Redactor.redact_string(message) if defined?(Legion::Logging::Redactor) && redaction_enabled?
        message = colorize_exception(message, level) if Legion::Logging.color

        Legion::Logging.log.public_send(level, message)
      ensure
        Thread.current[:legion_log_segments] = prev_segs
      end

      def format_exception_output(exception, event)
        lines = ["#{exception.class}: #{exception.message}"]

        context_line = build_context_line(event)
        lines << "  #{context_line}" unless context_line.empty?

        bt = exception.backtrace
        if bt&.any?
          bt.first(EXCEPTION_BACKTRACE_LIMIT).each { |frame| lines << "  #{frame}" }
          remaining = bt.length - EXCEPTION_BACKTRACE_LIMIT
          lines << "  ... #{remaining} more" if remaining.positive?
        end

        lines.join("\n")
      end

      def colorize_exception(message, level)
        color = EXCEPTION_COLORS[level] || :red
        lines = message.split("\n")
        lines[0] = Rainbow(lines[0]).color(color).bright
        lines[1..].each_with_index do |line, i|
          lines[i + 1] = Rainbow(line).color(color).faint
        end
        lines.join("\n")
      end

      def build_context_line(event)
        parts = []
        gn = event[:gem_name]
        gv = event[:lex_version]
        parts << (gv ? "#{gn}@#{gv}" : gn.to_s) if gn
        parts << "task:#{event[:task_id]}" if event[:task_id]
        parts << "conversation:#{event[:conversation_id]}" if event[:conversation_id]
        parts << "chain:#{event[:chain_id]}" if event[:chain_id]
        parts.join(' | ')
      end

      def redaction_enabled?
        return false unless defined?(Legion::Settings)

        loader = Legion::Settings.instance_variable_get(:@loader)
        return false unless loader

        loader.dig(:logging, :redaction, :enabled) == true
      rescue StandardError
        false
      end

      # -- Exception structured publish --

      def publish_exception(event, level)
        lex_name = event[:lex] || 'core'
        comp = event[:component_type] || :unknown
        routing_key = "legion.logging.exception.#{level}.#{lex_name}.#{comp}"

        headers = build_exception_headers(event, comp, level)
        properties = build_exception_properties(event, level)

        Legion::Logging.exception_writer.call(event, routing_key: routing_key, headers: headers, properties: properties)
      rescue StandardError => e
        Legion::Logging.warn("Failed to publish exception event: #{e.class}: #{e.message}")
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
        headers['x-task-id'] = event[:task_id].to_s if event[:task_id]
        headers['x-conversation-id'] = event[:conversation_id].to_s if event[:conversation_id]
        headers['x-chain-id'] = event[:chain_id].to_s if event[:chain_id]
        headers['x-user'] = event[:user].to_s if event[:user]
        headers
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
    end
  end
end
