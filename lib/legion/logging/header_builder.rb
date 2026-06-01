# frozen_string_literal: true

require 'securerandom'

module Legion
  module Logging
    module HeaderBuilder
      EXCEPTION_PRIORITY = { warn: 0, error: 5, fatal: 9 }.freeze

      private

      def build_exception_headers(event, comp, level)
        headers = {
          'legion_protocol_version' => '2.0',
          'x-error-fingerprint'     => event[:error_fingerprint],
          'x-exception-class'       => event[:exception_class],
          'x-handled'               => event[:handled].to_s,
          'x-gem-name'              => event[:gem_name].to_s,
          'x-lex-version'           => event[:lex_version].to_s,
          'x-component-type'        => comp.to_s,
          'x-level'                 => level.to_s
        }
        append_legion_version_header(headers)
        append_optional_header(headers, 'x-task-id', event[:task_id])
        append_optional_header(headers, 'x-conversation-id', event[:conversation_id])
        append_optional_header(headers, 'x-chain-id', event[:chain_id])
        append_optional_header(headers, 'x-user', event[:user])
        append_identity_headers(headers)
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

      def append_identity_headers(headers)
        return unless defined?(Legion::Identity::Process)
        return if Legion::Identity::Process.respond_to?(:resolved?) && !Legion::Identity::Process.resolved?

        id = identity_hash
        append_optional_header(headers, 'x-legion-identity-canonical-name', id[:canonical_name])
        append_optional_header(headers, 'x-legion-identity-trust', id[:trust])
        append_optional_header(headers, 'x-legion-identity-id', id[:id])
        append_optional_header(headers, 'x-legion-identity-kind', id[:kind])
        append_optional_header(headers, 'x-legion-identity-mode', id[:mode])
        append_optional_header(headers, 'x-legion-identity-source', id[:source])
        headers['x-legion-identity-db-principal-id'] = id[:db_principal_id] if id[:db_principal_id]
        headers['x-legion-identity-db-identity-id'] = id[:db_identity_id] if id[:db_identity_id]
      rescue StandardError
        nil
      end

      def append_optional_header(headers, key, value)
        return if value.nil?
        return if value.respond_to?(:empty?) && value.empty?

        headers[key] = value.to_s
      end

      def append_legion_version_header(headers)
        append_optional_header(headers, 'x-legion-version', Legion::VERSION) if defined?(Legion::VERSION)
      end

      def identity_hash
        process = Legion::Identity::Process
        return process.identity_hash if process.respond_to?(:identity_hash)

        {
          canonical_name: identity_value(process, :canonical_name),
          id:             identity_value(process, :id),
          kind:           identity_value(process, :kind),
          mode:           identity_value(process, :mode),
          source:         identity_value(process, :source),
          trust:          identity_value(process, :trust)
        }
      end

      def identity_value(process, method_name)
        process.public_send(method_name) if process.respond_to?(method_name)
      end

      def redaction_enabled?
        return false unless defined?(Legion::Settings)

        loader = Legion::Settings.instance_variable_get(:@loader)
        return false unless loader

        loader.dig(:logging, :redaction, :enabled) == true
      rescue StandardError
        false
      end
    end
  end
end
