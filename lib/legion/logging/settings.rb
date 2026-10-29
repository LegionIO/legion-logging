# frozen_string_literal: true

module Legion
  module Logging
    module Settings
      # Log levels forwarded to the transport bus (and in-process Hooks) by
      # default. Preserves historic behavior: only warn/error/fatal logs build a
      # structured event. Override at runtime via logging.transport.log_levels
      # (e.g. add :debug/:info) — see Methods#forwardable_log_levels.
      DEFAULT_FORWARD_LOG_LEVELS = %i[warn error fatal].freeze

      def self.default
        {
          level:              :info,
          trace:              true,
          trace_size:         4,
          extended:           true,
          backtrace_limit:    nil,
          forward_log_levels: DEFAULT_FORWARD_LOG_LEVELS
        }
      end

      def self.async_buffer_size
        return 10_000 unless defined?(Legion::Settings) && Legion::Settings.respond_to?(:[])
        return 10_000 unless Legion::Settings.respond_to?(:loaded?) ? Legion::Settings.loaded? : true

        logging = Legion::Settings[:logging]
        async = logging[:async] if logging.is_a?(Hash)
        async.is_a?(Hash) ? (async[:buffer_size] || 10_000) : 10_000
      end
    end
  end
end
