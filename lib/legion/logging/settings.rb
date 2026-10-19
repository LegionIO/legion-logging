# frozen_string_literal: true

module Legion
  module Logging
    module Settings
      def self.default
        {
          level:           :info,
          trace:           true,
          trace_size:      4,
          extended:        true,
          backtrace_limit: nil,
          rotation:        {
            enabled:     true,
            max_size_mb: 100,
            max_files:   5,
            stdio:       true
          }
        }
      end
    end
  end
end
