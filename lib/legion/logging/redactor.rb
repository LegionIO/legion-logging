# frozen_string_literal: true

module Legion
  module Logging
    module Redactor
      PATTERNS = {
        ssn:            /\b\d{3}-\d{2}-\d{4}\b/,
        email:          /\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/,
        phone:          /\b(?:\+1[-.\s]?)?\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}\b/,
        mrn:            /\bMRN[:\s]*\d{6,10}\b/i,
        dob:            %r{\bDOB[:\s]*\d{1,2}[/-]\d{1,2}[/-]\d{2,4}\b}i,
        credit_card:    /\b\d{4}[-\s]?\d{4}[-\s]?\d{4}[-\s]?\d{4}\b/,
        vault_token:    /\bhvs\.[A-Za-z0-9_-]{20,}\b/,
        vault_lease_id: %r{\b[a-z_-]+/creds/[a-z_-]+/[A-Za-z0-9-]{36}\b},
        jwt:            /\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b/,
        vault_uri:      %r{vault://[^"',\]\x7d\s]+},
        lease_uri:      %r{lease://[^"',\]\x7d\s]+},
        bearer_token:   %r{Bearer\s+[A-Za-z0-9._~+/=-]{20,}}i
      }.freeze

      SENSITIVE_FIELDS = %w[
        password
        secret
        token
        api_key
        access_key
        private_key
        public_key
        authorization
      ].freeze
      SENSITIVE_SUFFIXES = %w[token secret password passphrase credential credentials].freeze
      SAFE_KEY_FIELDS = %w[primary_key foreign_key sort_key partition_key routing_key].freeze

      REDACTED = '[REDACTED]'

      class << self
        def redact(event)
          return event unless event.is_a?(Hash)

          event.each_with_object({}) do |(key, value), result|
            result[key] = sensitive_field?(key) ? REDACTED : redact_value(value)
          end
        end

        def redact_value(value)
          case value
          when String then redact_string(value)
          when Hash   then redact(value)
          when Array  then value.map { |v| redact_value(v) }
          else value
          end
        end

        def redact_string(str)
          result = str.dup
          all_patterns.each_value { |pattern| result.gsub!(pattern, REDACTED) }
          result
        end

        private

        def sensitive_field?(key)
          normalized = normalize_key(key)
          return false if SAFE_KEY_FIELDS.include?(normalized)
          return true if SENSITIVE_FIELDS.include?(normalized)
          return true if normalized.include?('authorization')
          return true if normalized.start_with?('auth_') || normalized.end_with?('_auth')
          return true if normalized.start_with?('bearer_') || normalized.end_with?('_bearer')
          return true if SENSITIVE_SUFFIXES.any? { |suffix| normalized.end_with?("_#{suffix}") }

          %w[api access client private public auth secret signing session].any? do |prefix|
            normalized == "#{prefix}_key"
          end
        end

        def all_patterns
          @all_patterns ||= build_patterns
        end

        def build_patterns
          patterns = PATTERNS.dup
          custom = custom_patterns
          custom.each { |name, regex| patterns[name.to_sym] = regex }
          patterns
        end

        def custom_patterns
          return {} unless defined?(Legion::Settings)

          raw = Legion::Settings.dig(:logging, :redactor, :custom_patterns)
          return {} unless raw.is_a?(Hash)

          raw.each_with_object({}) do |(name, pattern_str), acc|
            acc[name] = Regexp.new(pattern_str)
          rescue RegexpError => e
            warn("Legion::Logging::Redactor#custom_patterns skipping invalid pattern #{name}: #{e.message}")
          end
        end

        def reset_pattern_cache!
          @all_patterns = nil
        end

        def refresh_patterns!
          reset_pattern_cache!
        end

        public :refresh_patterns!

        def normalize_key(key)
          key.to_s.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
        end
      end
    end
  end
end
