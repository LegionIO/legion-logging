# frozen_string_literal: true

module Legion
  module Logging
    module Hooks
      class << self
        def on_fatal(&block)
          fatal_hooks << block
        end

        def on_error(&block)
          error_hooks << block
        end

        def on_warn(&block)
          warn_hooks << block
        end

        def fire(level, message, event)
          return unless @enabled

          hooks_for(level).each do |hook|
            hook.call(message, event)
          rescue StandardError => e
            warn("Legion::Logging::Hooks#fire callback failed: #{e.message}")
          end
        end

        def enable_hooks!
          @enabled = true
        end

        def disable_hooks!
          @enabled = false
        end

        def enabled?
          @enabled || false
        end

        def clear_hooks!
          @fatal_hooks = []
          @error_hooks = []
          @warn_hooks = []
        end

        private

        def hooks_for(level)
          case level.to_sym
          when :fatal then fatal_hooks
          when :error then error_hooks
          when :warn  then warn_hooks
          else []
          end
        end

        def fatal_hooks
          @fatal_hooks ||= []
        end

        def error_hooks
          @error_hooks ||= []
        end

        def warn_hooks
          @warn_hooks ||= []
        end
      end
    end
  end
end
