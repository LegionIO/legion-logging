# frozen_string_literal: true

module Legion
  module Logging
    module Hooks
      @hooks = { fatal: [], error: [], warn: [] }
      @enabled = false

      class << self
        attr_reader :hooks

        def enabled?
          @enabled
        end

        def enable!
          @enabled = true
        end

        def disable!
          @enabled = false
        end

        def clear!
          @hooks.each_value(&:clear)
        end

        def register(level, &block)
          @hooks[level] << block
        end

        def fire(level, event)
          return unless @enabled
          return if @hooks[level].empty?

          @hooks[level].each do |hook|
            hook.call(event)
          rescue StandardError => e
            warn("Legion::Logging::Hooks#fire hook failed at level=#{level}: #{e.message}")
            nil
          end
        end
      end
    end
  end
end
