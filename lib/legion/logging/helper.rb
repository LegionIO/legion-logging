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
        current_generation =
          if defined?(Legion::Logging) && Legion::Logging.respond_to?(:configuration_generation)
            Legion::Logging.configuration_generation
          else
            0
          end

        if !defined?(@log) || @log.nil? || @log_generation != current_generation
          @log = Legion::Logging::TaggedLogger.new(segments: derive_log_segments, **tagged_logger_settings)
          @log_generation = current_generation
        end

        @log
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

        event = build_exception_event(
          exception:       exception,
          level:           level,
          spec:            spec,
          handled:         handled,
          task_id:         task_id || ctx[:task_id],
          payload_summary: opts.empty? ? nil : opts
        )

        event[:conversation_id] ||= ctx[:conversation_id]
        event[:chain_id] ||= ctx[:chain_id]
        event[:log_segments] = segments
        event[:method] = Thread.current[:legion_log_method]

        event = Legion::Logging::Redactor.redact(event) if defined?(Legion::Logging::Redactor)

        write_exception_to_log(exception, event, level, segments)
        publish_exception(event, level) if structured_exception_support?
      end

      private

      def build_exception_event(exception:, level:, spec:, handled:, task_id:, payload_summary:)
        unless structured_exception_support?
          return fallback_exception_event(
            exception:       exception,
            level:           level,
            spec:            spec,
            handled:         handled,
            task_id:         task_id,
            payload_summary: payload_summary
          )
        end

        Legion::Logging::EventBuilder.build_exception(
          exception:       exception,
          level:           level,
          lex:             log_name,
          component_type:  derive_component_type,
          gem_name:        gem_name,
          lex_version:     spec&.version&.to_s,
          gem_path:        spec&.full_gem_path,
          source_code_uri: spec&.metadata&.[]('source_code_uri'),
          handled:         handled,
          task_id:         task_id,
          payload_summary: payload_summary,
          caller_offset:   3
        )
      end

      def fallback_exception_event(exception:, level:, spec:, handled:, task_id:, payload_summary:)
        {
          exception_class:   exception.class.to_s,
          message:           exception.message,
          level:             level,
          lex:               log_name,
          component_type:    derive_component_type,
          gem_name:          gem_name,
          lex_version:       spec&.version&.to_s,
          gem_path:          spec&.full_gem_path,
          source_code_uri:   spec&.metadata&.[]('source_code_uri'),
          handled:           handled,
          task_id:           task_id,
          payload_summary:   payload_summary,
          error_fingerprint: SecureRandom.uuid
        }
      end

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

      def instance_log_level(default = Legion::Logging::Settings.default[:level] || :info)
        component_level = component_log_level
        return component_level if present_log_level?(component_level)

        global_level = global_log_level
        return global_level if present_log_level?(global_level)

        Legion::Logging::Settings.default[:level] || default
      rescue StandardError => e
        Legion::Logging.warn("Legion::Logging::Helper.instance_log_level(#{default}) failed: #{e.class}: #{e.message}")
        Legion::Logging::Settings.default[:level] || default
      end

      def global_logger_settings
        defaults = defined?(Legion::Logging::Settings) ? Legion::Logging::Settings.default.dup : {}
        settings_logging = if defined?(Legion::Settings) &&
                              Legion::Settings.respond_to?(:loaded?) &&
                              Legion::Settings.loaded?
                             raw = Legion::Settings[:logging]
                             raw.is_a?(Hash) ? raw : {}
                           else
                             {}
                           end
        runtime_logging = if defined?(Legion::Logging) &&
                             Legion::Logging.respond_to?(:current_settings)
                            current = Legion::Logging.current_settings
                            current.is_a?(Hash) ? current : {}
                          else
                            {}
                          end

        defaults.merge(settings_logging).merge(runtime_logging)
      end

      def resolve_logger_settings
        base = global_logger_settings
        override = component_logger_settings
        merged = override ? base.merge(override) : base
        merged.merge(
          level:      instance_log_level(merged[:level]),
          trace:      instance_trace(merged[:trace]),
          trace_size: instance_trace_size(merged[:trace_size]),
          extended:   instance_extended(merged[:extended])
        )
      rescue StandardError
        defined?(Legion::Logging::Settings) ? Legion::Logging::Settings.default : {}
      end

      def tagged_logger_settings
        settings = resolve_logger_settings
        {
          level:      settings[:level],
          trace:      settings[:trace],
          trace_size: settings[:trace_size],
          extended:   settings[:extended]
        }
      end

      def component_logger_settings
        source = component_settings
        raw = settings_value(source, :logger)
        raw.is_a?(Hash) ? raw : nil
      end

      def component_log_level
        source = component_settings
        return unless source.is_a?(Hash)

        settings_value(source, :log_level) ||
          settings_value(source, :logger_level) ||
          settings_value(source, :logger, :level)
      end

      def instance_trace(default = Legion::Logging::Settings.default[:trace])
        component_trace = component_logger_option(:trace)
        return component_trace unless component_trace.nil?

        global_trace = global_logger_option(:trace)
        return global_trace unless global_trace.nil?

        Legion::Logging::Settings.default[:trace].nil? ? default : Legion::Logging::Settings.default[:trace]
      rescue StandardError => e
        Legion::Logging.warn("Legion::Logging::Helper.instance_trace(#{default}) failed: #{e.class}: #{e.message}")
        Legion::Logging::Settings.default[:trace].nil? ? default : Legion::Logging::Settings.default[:trace]
      end

      def instance_trace_size(default = Legion::Logging::Settings.default[:trace_size] || 4)
        component_trace_size = component_logger_option(:trace_size)
        return component_trace_size unless component_trace_size.nil?

        global_trace_size = global_logger_option(:trace_size)
        return global_trace_size unless global_trace_size.nil?

        Legion::Logging::Settings.default[:trace_size] || default
      rescue StandardError => e
        Legion::Logging.warn("Legion::Logging::Helper.instance_trace_size(#{default}) failed: #{e.class}: #{e.message}")
        Legion::Logging::Settings.default[:trace_size] || default
      end

      def instance_extended(default = Legion::Logging::Settings.default[:extended])
        component_extended = component_logger_option(:extended)
        return component_extended unless component_extended.nil?

        global_extended = global_logger_option(:extended)
        return global_extended unless global_extended.nil?

        Legion::Logging::Settings.default[:extended].nil? ? default : Legion::Logging::Settings.default[:extended]
      rescue StandardError => e
        Legion::Logging.warn("Legion::Logging::Helper.instance_extended(#{default}) failed: #{e.class}: #{e.message}")
        Legion::Logging::Settings.default[:extended].nil? ? default : Legion::Logging::Settings.default[:extended]
      end

      def component_settings
        local = local_settings_hash
        return local if local.is_a?(Hash)

        legion_component_settings
      end

      def local_settings_hash
        return unless respond_to?(:settings, true)

        source = settings
        source if source.is_a?(Hash)
      rescue StandardError
        nil
      end

      def legion_component_settings
        return unless defined?(Legion::Settings)
        return unless Legion::Settings.respond_to?(:loaded?) ? Legion::Settings.loaded? : true

        key = derive_component_settings_key
        return unless key

        top_level = Legion::Settings[key]
        return top_level if top_level.is_a?(Hash)

        extension_settings = Legion::Settings.dig(:extensions, key)
        extension_settings if extension_settings.is_a?(Hash)
      rescue StandardError
        nil
      end

      def derive_component_settings_key
        base = log_name
        return unless base

        base.to_s.tr('-', '_').to_sym
      rescue StandardError
        nil
      end

      def global_log_level
        runtime_level = if defined?(Legion::Logging) &&
                           Legion::Logging.respond_to?(:current_settings)
                          settings_value(Legion::Logging.current_settings, :level)
                        end
        return runtime_level if present_log_level?(runtime_level)

        return unless defined?(Legion::Settings)
        return unless Legion::Settings.respond_to?(:loaded?) ? Legion::Settings.loaded? : true

        settings_value(Legion::Settings[:logging], :level) || Legion::Settings[:level]
      rescue StandardError
        nil
      end

      def component_logger_option(key)
        source = component_settings
        return unless source.is_a?(Hash)

        return settings_value(source, key) if settings_key?(source, key)
        return settings_value(source, :logger, key) if settings_key?(source, :logger, key)

        nil
      end

      def global_logger_option(key)
        runtime_value = if defined?(Legion::Logging) &&
                           Legion::Logging.respond_to?(:current_settings)
                          settings_value(Legion::Logging.current_settings, key)
                        end
        return runtime_value unless runtime_value.nil?

        return unless defined?(Legion::Settings)
        return unless Legion::Settings.respond_to?(:loaded?) ? Legion::Settings.loaded? : true

        settings_value(Legion::Settings[:logging], key)
      rescue StandardError
        nil
      end

      def settings_value(source, *keys)
        missing = Object.new
        current = source
        keys.each do |key|
          current =
            if current.is_a?(Hash) && current.key?(key)
              current[key]
            elsif current.is_a?(Hash) && current.key?(key.to_s)
              current[key.to_s]
            else
              missing
            end

          break if current.equal?(missing)
        end

        current.equal?(missing) ? nil : current
      end

      def settings_key?(source, *keys)
        current = source
        keys.each do |key|
          return false unless current.is_a?(Hash)

          next_key = if current.key?(key)
                       key
                     elsif current.key?(key.to_s)
                       key.to_s
                     else
                       return false
                     end
          current = current[next_key]
        end

        true
      end

      def present_log_level?(value)
        !value.nil? && !(value.respond_to?(:empty?) && value.empty?)
      end

      # -- Exception stdout/file output --

      def write_exception_to_log(exception, event, level, segments)
        prev_segs = Thread.current[:legion_log_segments]
        Thread.current[:legion_log_segments] = segments

        message = format_exception_output(exception, event)
        message = Legion::Logging::Redactor.redact_string(message) if defined?(Legion::Logging::Redactor) && redaction_enabled?
        message = colorize_exception(message, level) if Legion::Logging.respond_to?(:color) && Legion::Logging.color

        logger = Legion::Logging.respond_to?(:log) ? Legion::Logging.log : nil
        if logger.respond_to?(level)
          logger.public_send(level, message)
        elsif Legion::Logging.respond_to?(level)
          Legion::Logging.public_send(level, message)
        end
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
        return unless structured_exception_support?

        lex_name = event[:lex] || 'core'
        comp = event[:component_type] || :unknown
        routing_key = "legion.logging.exception.#{level}.#{lex_name}.#{comp}"

        headers = build_exception_headers(event, comp, level)
        properties = build_exception_properties(event, level)

        Legion::Logging.exception_writer.call(event, routing_key: routing_key, headers: headers, properties: properties)
      rescue StandardError => e
        Legion::Logging.warn("Failed to publish exception event: #{e.class}: #{e.message}") if Legion::Logging.respond_to?(:warn)
      end

      def structured_exception_support?
        defined?(Legion::Logging::EventBuilder) &&
          Legion::Logging.respond_to?(:exception_writer)
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
