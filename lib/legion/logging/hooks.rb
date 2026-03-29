# frozen_string_literal: true

module Legion
  module Logging
    module Hooks
      class << self
        def on_warn(&block)
          warn_hooks << block
        end

        def on_error(&block)
          error_hooks << block
        end

        def on_fatal(&block)
          fatal_hooks << block
        end

        def fire(level, message, event = {})
          hooks = case level
                  when :warn  then warn_hooks
                  when :error then error_hooks
                  when :fatal then fatal_hooks
                  else []
                  end
          hooks.map do |hook|
            hook.call(message, event)
          rescue StandardError => e
            Kernel.warn("Legion::Logging::Hooks fire failed for level=#{level}: #{e.message}")
            nil
          end
        end

        def clear_hooks!
          @warn_hooks  = []
          @error_hooks = []
          @fatal_hooks = []
        end

        private

        def warn_hooks
          @warn_hooks ||= []
        end

        def error_hooks
          @error_hooks ||= []
        end

        def fatal_hooks
          @fatal_hooks ||= []
        end
      end
    end
  end
end
