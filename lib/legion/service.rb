# frozen_string_literal: true

module Legion
  module Service
    def self.register_logging_hooks
      return unless defined?(Legion::Logging::Hooks)
      return unless defined?(Legion::Transport)

      Legion::Logging::Hooks.on_warn do |message, event|
        Legion::Transport::Exchanges::Logging.publish(event.merge(level: :warn, message: message))
      rescue StandardError => e
        Kernel.warn("register_logging_hooks on_warn publish failed: #{e.message}")
      end

      Legion::Logging::Hooks.on_error do |message, event|
        Legion::Transport::Exchanges::Logging.publish(event.merge(level: :error, message: message))
      rescue StandardError => e
        Kernel.warn("register_logging_hooks on_error publish failed: #{e.message}")
      end

      Legion::Logging::Hooks.on_fatal do |message, event|
        Legion::Transport::Exchanges::Logging.publish(event.merge(level: :fatal, message: message))
      rescue StandardError => e
        Kernel.warn("register_logging_hooks on_fatal publish failed: #{e.message}")
      end
    end
  end
end
