# frozen_string_literal: true

require 'legion/logging/version'
require 'legion/logging/settings'
require 'legion/logging/logger'
require 'legion/logging/methods'
require 'legion/logging/builder'
require 'legion/logging/event_builder'
require 'legion/logging/async_writer'
require 'legion/logging/tagged_logger'
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

      DEFAULT_LOG_WRITER = ->(_event, routing_key:) {}
      DEFAULT_EXCEPTION_WRITER = ->(_event, routing_key:, headers:, properties:) {}

      def log_writer
        @log_writer || DEFAULT_LOG_WRITER
      end

      def exception_writer
        @exception_writer || DEFAULT_EXCEPTION_WRITER
      end

      def current_settings
        (@current_settings || {}).dup
      end

      def configuration_generation
        @configuration_generation || 0
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

      def setup(level: 'debug', format: :text, async: true, **options)
        output(**options)
        log_level(level)
        log_format(format: format, **options)
        @color = options[:color]
        @color = format != :json && (options[:color] || (options[:color].nil? && options[:log_file].nil?))
        @current_settings = {
          level:       level,
          format:      format.to_sym,
          async:       async,
          trace:       options.fetch(:trace, true),
          trace_size:  options.fetch(:trace_size, 4),
          extended:    options.fetch(:extended, true),
          log_file:    options[:log_file],
          log_stdout:  options[:log_stdout],
          include_pid: options.fetch(:include_pid, false),
          color:       @color
        }.freeze
        @configuration_generation = configuration_generation + 1
        Legion::Logging::Redactor.refresh_patterns! if defined?(Legion::Logging::Redactor)
        if async
          buffer = if defined?(Legion::Settings) && Legion::Settings.respond_to?(:[])
                     logging_settings = Legion::Settings[:logging]
                     async_settings = logging_settings[:async] if logging_settings.is_a?(Hash)
                     async_settings[:buffer_size] if async_settings.is_a?(Hash)
                   end
          buffer ||= 10_000
          start_async_writer(buffer_size: buffer)
        else
          stop_async_writer
        end
      end
    end
  end
end
