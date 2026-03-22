# frozen_string_literal: true

module Legion
  module Logging
    module EventBuilder
      class << self
        def build(level:, message:, lex: nil, lex_segments: nil, context: nil, caller_offset: 2) # rubocop:disable Metrics/ParameterLists
          event = base_fields(level, message)
          event[:lex] = derive_lex_source(lex, lex_segments)
          add_node(event)
          add_caller_info(event, caller_offset)
          add_exception_info(event, message)
          add_gem_info(event, event[:lex])
          event[:context] = context if context
          event.compact
        end

        private

        def base_fields(level, message)
          {
            timestamp: Time.now.utc.iso8601(3),
            level:     level,
            message:   message.is_a?(Exception) ? message.message : strip_ansi(message.to_s),
            pid:       ::Process.pid,
            thread:    Thread.current.object_id
          }
        end

        def derive_lex_source(lex, lex_segments)
          if lex_segments.is_a?(Array) && !lex_segments.empty?
            "lex-#{lex_segments.join('-')}"
          elsif lex && !lex.to_s.empty?
            "lex-#{lex}"
          end
        end

        def add_node(event)
          return unless defined?(Legion::Settings)

          name = begin
            Legion::Settings[:client][:name]
          rescue StandardError => e
            warn("Legion::Logging::EventBuilder#add_node failed: #{e.message}")
            nil
          end
          event[:node] = name if name
        end

        def add_caller_info(event, offset)
          loc = caller_locations(offset + 1, 1)&.first
          return unless loc

          event[:caller] = {
            file:     loc.absolute_path || loc.path,
            function: loc.base_label,
            line:     loc.lineno
          }
        end

        def add_exception_info(event, message)
          return unless message.is_a?(Exception)

          event[:exception] = {
            class:   message.class.name,
            message: message.message
          }
          event[:backtrace] = message.backtrace if message.backtrace
        end

        def add_gem_info(event, lex_source)
          return unless lex_source

          spec = Gem::Specification.find_by_name(lex_source)
          event[:gem] = {
            name:            spec.name,
            version:         spec.version.to_s,
            source_code_uri: spec.metadata['source_code_uri'],
            homepage:        spec.metadata['homepage_uri'] || spec.homepage,
            path:            spec.full_gem_path
          }.compact
        rescue Gem::MissingSpecError, ArgumentError => e
          warn("Legion::Logging::EventBuilder#add_gem_info failed for #{lex_source}: #{e.message}")
          nil
        end

        def strip_ansi(str)
          str.gsub(/\e\[[0-9;]*m/, '')
        end
      end
    end
  end
end
