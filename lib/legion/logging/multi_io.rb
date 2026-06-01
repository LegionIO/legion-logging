# frozen_string_literal: true

module Legion
  module Logging
    class MultiIO
      def initialize(*targets)
        @targets = targets.flatten
      end

      def write(message)
        @targets.each do |t|
          t.write(message)
        rescue StandardError => e
          warn("Legion::Logging::MultiIO#write failed for #{t.class}: #{e.message}")
        end
      end

      def close
        @targets.each { |t| t.close unless [$stdout, $stderr].include?(t) }
      end

      def flush
        @targets.each { |t| t.flush if t.respond_to?(:flush) }
      end
    end
  end
end
