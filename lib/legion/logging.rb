# frozen_string_literal: true

require 'legion/logging/version'
require 'legion/logging/logger'
require 'legion/logging/methods'
require 'legion/logging/builder'
require 'legion/logging/hooks'
require 'legion/logging/event_builder'
require 'legion/logging/async_writer'

require 'json'
require 'logger'
require 'rainbow'

module Legion
  module Logging
    class << self
      include Legion::Logging::Methods
      include Legion::Logging::Builder

      def on_fatal(&)  = Hooks.register(:fatal, &)
      def on_error(&)  = Hooks.register(:error, &)
      def on_warn(&)   = Hooks.register(:warn, &)
      def enable_hooks!     = Hooks.enable!
      def disable_hooks!    = Hooks.disable!
      def clear_hooks!      = Hooks.clear!

      attr_reader :color

      def setup(level: 'info', format: :text, async: true, **options)
        output(**options)
        log_level(level)
        log_format(format: format, **options)
        @color = options[:color]
        @color = format != :json && (options[:color] || (options[:color].nil? && options[:log_file].nil?))
        if async
          buffer = if defined?(Legion::Settings)
                     Legion::Settings.dig(:logging, :async, :buffer_size) || 10_000
                   else
                     10_000
                   end
          start_async_writer(buffer_size: buffer)
        else
          stop_async_writer
        end
      end
    end
  end
end
