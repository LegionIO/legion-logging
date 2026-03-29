# frozen_string_literal: true

require 'legion/logging/version'
require 'legion/logging/logger'
require 'legion/logging/methods'
require 'legion/logging/builder'
require 'legion/logging/event_builder'
require 'legion/logging/async_writer'
require 'legion/logging/helper'
require 'legion/logging/category_registry'
require 'legion/logging/hooks'

require 'json'
require 'logger'
require 'rainbow'

module Legion
  module Logging
    class << self
      include Legion::Logging::Methods
      include Legion::Logging::Builder

      attr_reader :color
      attr_writer :log_writer, :exception_writer

      DEFAULT_LOG_WRITER       = ->(_event, routing_key:) {}
      DEFAULT_EXCEPTION_WRITER = ->(_event, routing_key:, headers:, properties:) {}

      def log_writer
        @log_writer || DEFAULT_LOG_WRITER
      end

      def exception_writer
        @exception_writer || DEFAULT_EXCEPTION_WRITER
      end

      def register_category(name, description: nil, expected_fields: [])
        CategoryRegistry.register_category(name, description: description, expected_fields: expected_fields)
      end

      def registered_categories
        CategoryRegistry.registered_categories
      end

      def on_fatal(&)
        Hooks.on_fatal(&)
      end

      def on_error(&)
        Hooks.on_error(&)
      end

      def on_warn(&)
        Hooks.on_warn(&)
      end

      def enable_hooks!
        Hooks.enable_hooks!
      end

      def disable_hooks!
        Hooks.disable_hooks!
      end

      def clear_hooks!
        Hooks.clear_hooks!
      end

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
