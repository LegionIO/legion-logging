# frozen_string_literal: true

module Legion
  module Logging
    module Redactor
      PATTERNS = {
        ssn:         /\b\d{3}-\d{2}-\d{4}\b/,
        email:       /\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/,
        phone:       /\b(?:\+1[-.\s]?)?\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}\b/,
        mrn:         /\bMRN[:\s]*\d{6,10}\b/i,
        dob:         %r{\bDOB[:\s]*\d{1,2}[/-]\d{1,2}[/-]\d{2,4}\b}i,
        credit_card: /\b\d{4}[-\s]?\d{4}[-\s]?\d{4}[-\s]?\d{4}\b/
      }.freeze

      SENSITIVE_FIELDS = %w[password secret token api_key authorization].freeze

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
          SENSITIVE_FIELDS.include?(key.to_s.downcase)
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
      end
    end
  end
end
