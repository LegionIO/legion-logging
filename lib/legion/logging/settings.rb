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
          backtrace_limit: nil
        }
      end
    end
  end
end
