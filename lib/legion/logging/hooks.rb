# frozen_string_literal: true

module Legion
  module Logging
    module Hooks
      @mutex       = Mutex.new
      @warn_hooks  = []
      @error_hooks = []
      @fatal_hooks = []

      class << self
        def on_warn(&block)
          @mutex.synchronize { @warn_hooks << block }
        end

        def on_error(&block)
          @mutex.synchronize { @error_hooks << block }
        end

        def on_fatal(&block)
          @mutex.synchronize { @fatal_hooks << block }
        end

        def fire(level, message)
          hooks = @mutex.synchronize do
            case level
            when :warn  then @warn_hooks.dup
            when :error then @error_hooks.dup
            when :fatal then @fatal_hooks.dup
            else             []
            end
          end
          hooks.each do |hook|
            hook.call(message)
          rescue StandardError => e
            Kernel.warn("Legion::Logging::Hooks fire error (level=#{level}): #{e.message}")
          end
          nil
        end

        private

        def clear_hooks!
          @mutex.synchronize do
            @warn_hooks.clear
            @error_hooks.clear
            @fatal_hooks.clear
          end
        end
      end
    end
  end
end
