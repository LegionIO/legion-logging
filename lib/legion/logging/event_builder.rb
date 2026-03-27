# frozen_string_literal: true

require 'digest'
require 'json'

module Legion
  module Logging
    module EventBuilder
      MAX_MESSAGE_BYTES        = 4096
      MAX_PAYLOAD_BYTES        = 8192
      MAX_TOTAL_BYTES          = 65_536
      BACKTRACE_FALLBACK_FRAMES = 20

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

        def build_exception( # rubocop:disable Metrics/ParameterLists
          exception:,
          level:,
          lex: nil,
          component_type: nil,
          gem_name: nil,
          lex_version: nil,
          gem_path: nil,
          source_code_uri: nil,
          handled: false,
          payload_summary: nil,
          task_id: nil,
          caller_offset: 2,
          **extra
        )
          bt = Array(exception.backtrace)
          cf_file, cf_line, cf_func = parse_backtrace_location(bt.first) ||
                                      caller_location(caller_offset)

          event = {
            timestamp:       Time.now.utc.iso8601(3),
            level:           level,
            exception_class: exception.class.name,
            message:         truncate_bytes(exception.message.to_s, MAX_MESSAGE_BYTES),
            backtrace:       bt,
            caller_file:     cf_file,
            caller_line:     cf_line,
            caller_function: cf_func,
            lex:             lex,
            component_type:  component_type,
            gem_name:        gem_name,
            lex_version:     lex_version,
            gem_path:        gem_path,
            source_code_uri: source_code_uri,
            legion_versions: legion_versions,
            ruby_version:    "#{RUBY_VERSION} #{RUBY_PLATFORM}",
            handled:         handled,
            pid:             ::Process.pid,
            thread:          Thread.current.object_id
          }

          event[:task_id] = task_id if task_id
          event[:payload_summary] = truncate_payload(payload_summary) if payload_summary

          add_node(event)
          add_user(event)
          add_session_context(event)

          event[:error_fingerprint] = fingerprint(
            exception_class: exception.class.name,
            message:         event[:message],
            caller_file:     cf_file.to_s,
            caller_line:     cf_line.to_i,
            caller_function: cf_func.to_s,
            gem_name:        gem_name.to_s,
            component_type:  component_type.to_s,
            backtrace:       bt
          )

          extra.each { |k, v| event[k] = v unless event.key?(k) }

          enforce_total_size!(event)
          event.compact
        end

        def fingerprint( # rubocop:disable Metrics/ParameterLists
          exception_class:,
          message:,
          caller_file:,
          caller_line:,
          caller_function:,
          gem_name:,
          component_type:,
          backtrace:
        )
          norm_msg = normalize_message(message.to_s)
          norm_file = normalize_path(caller_file.to_s)
          norm_bt = Array(backtrace).first(5).map { |l| normalize_path(l.to_s) }.join('|')

          raw = [
            exception_class.to_s,
            norm_msg,
            norm_file,
            caller_line.to_s,
            caller_function.to_s,
            gem_name.to_s,
            component_type.to_s,
            norm_bt
          ].join(':')

          Digest::MD5.hexdigest(raw)
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
            lex_segments.join('-')
          elsif lex && !lex.to_s.empty?
            lex.to_s
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

          spec = resolve_gem_spec(lex_source)
          return unless spec

          event[:gem] = {
            name:            spec.name,
            version:         spec.version.to_s,
            source_code_uri: spec.metadata['source_code_uri'],
            homepage:        spec.metadata['homepage_uri'] || spec.homepage,
            path:            spec.full_gem_path
          }.compact
        end

        def resolve_gem_spec(name)
          [name, "lex-#{name}", "legion-#{name}"].each do |candidate|
            return Gem::Specification.find_by_name(candidate)
          rescue Gem::MissingSpecError
            next
          end
          nil
        end

        def strip_ansi(str)
          str.gsub(/\e\[[0-9;]*m/, '')
        end

        # New private helpers for build_exception

        def add_user(event)
          identity = if defined?(Legion::Extensions::Helpers::Secret) &&
                        Legion::Extensions::Helpers::Secret.respond_to?(:resolved_identity)
                       Legion::Extensions::Helpers::Secret.resolved_identity
                     else
                       ENV.fetch('USER', nil)
                     end
          event[:user] = identity
        end

        def add_session_context(event)
          return unless defined?(Legion::Context)

          session = begin
            Legion::Context.current_session
          rescue StandardError
            nil
          end
          return unless session

          event[:conversation_id] = session.session_id
        end

        def parse_backtrace_location(frame)
          return nil unless frame.is_a?(String)

          # Format: /path/to/file.rb:42:in `method_name`
          if (m = frame.match(/\A(.+):(\d+):in `([^`]+)`\z/))
            [m[1], m[2].to_i, m[3]]
          elsif (m = frame.match(/\A(.+):(\d+)\z/))
            [m[1], m[2].to_i, nil]
          end
        end

        def caller_location(offset)
          loc = caller_locations(offset + 2, 1)&.first
          return [nil, nil, nil] unless loc

          [loc.absolute_path || loc.path, loc.lineno, loc.base_label]
        end

        def normalize_message(msg)
          msg
            .gsub(/0x[0-9a-f]+/i, '0xXXX')
            .gsub(/#<[A-Z][A-Za-z:]*:0xXXX>/, '#<Class:0xXXX>')
            .gsub(/\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b/, 'X.X.X.X')
        end

        def normalize_path(path)
          path.gsub(/-\d+\.\d+[\d.]*/, '')
        end

        def legion_versions
          Gem::Specification
            .select { |s| s.name.start_with?('legion-', 'lex-') }
            .to_h { |s| [s.name, s.version.to_s] }
        end

        def truncate_bytes(str, max)
          return str if str.bytesize <= max

          str.byteslice(0, max).scrub
        end

        def truncate_payload(payload)
          return nil unless payload

          str = payload.is_a?(String) ? payload : ::JSON.generate(payload)
          truncate_bytes(str, MAX_PAYLOAD_BYTES)
        end

        def enforce_total_size!(event)
          return if ::JSON.generate(event).bytesize <= MAX_TOTAL_BYTES

          event.delete(:payload_summary)
          return if ::JSON.generate(event).bytesize <= MAX_TOTAL_BYTES

          bt = event[:backtrace]
          event[:backtrace] = bt.first(BACKTRACE_FALLBACK_FRAMES) if bt.is_a?(Array)
          return if ::JSON.generate(event).bytesize <= MAX_TOTAL_BYTES

          event[:message] = truncate_bytes(event[:message].to_s, 1024)
        end
      end
    end
  end
end
