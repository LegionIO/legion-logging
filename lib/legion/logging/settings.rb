# frozen_string_literal: true

module Legion
  module Logging
    module Settings
      def self.default
        {
          level:      :info,
          trace:      false,
          trace_size: 4,
          extended:   false
        }
      end
    end
  end
end
