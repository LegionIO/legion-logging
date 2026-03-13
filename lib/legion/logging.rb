# frozen_string_literal: true

require 'legion/logging/version'
require 'legion/logging/logger'
require 'legion/logging/methods'
require 'legion/logging/builder'

require 'json'
require 'logger'
require 'rainbow'

module Legion
  module Logging
    class << self
      include Legion::Logging::Methods
      include Legion::Logging::Builder

      attr_reader :color

      def setup(level: 'info', format: :text, **options)
        output(**options)
        log_level(level)
        log_format(format: format, **options)
        @color = options[:color]
        @color = format != :json && (options[:color] || (options[:color].nil? && options[:log_file].nil?))
      end
    end
  end
end
