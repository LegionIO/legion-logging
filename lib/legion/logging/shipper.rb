# frozen_string_literal: true

require_relative 'redactor'
require_relative 'shipper/file_transport'
require_relative 'shipper/http_transport'

module Legion
  module Logging
    module Shipper
      LEVEL_ORDER = %w[debug info warn error fatal].freeze

      TRANSPORTS = {
        file: FileTransport,
        http: HttpTransport
      }.freeze

      class << self
        def ship(event)
          return unless enabled?
          return unless shippable_level?(event[:level] || event['level'])

          redacted  = Redactor.redact(event)
          transport = TRANSPORTS[transport_type]
          buffer_event(redacted) if transport
        end

        def flush
          @mutex ||= Mutex.new
          batch = @mutex.synchronize do
            return true if @buffer.nil? || @buffer.empty?

            flushed = @buffer.dup
            @buffer.clear
            flushed
          end

          transport = TRANSPORTS[transport_type]
          return true unless transport

          delivered = deliver(transport, batch)
          @mutex.synchronize { @buffer.prepend(*batch) } unless delivered
          delivered
        end

        def start
          @start_mutex ||= Mutex.new
          @start_mutex.synchronize do
            return unless enabled?
            return if @flush_thread&.alive?

            @buffer ||= []
            @mutex  ||= Mutex.new
            @running = true
            interval = flush_interval
            @flush_thread = Thread.new do
              while @running
                sleep interval
                flush
              end
            end
            @flush_thread.name = 'legion-log-shipper'
            @flush_thread.abort_on_exception = false
          end
        end

        def stop
          @running = false
          thread = @flush_thread
          @flush_thread = nil
          thread&.join(5)
          flush
        end

        def enabled?
          return false unless defined?(Legion::Settings)

          Legion::Settings.dig(:logging, :shipper, :enabled) == true
        end

        private

        def buffer_event(event)
          @buffer ||= []
          @mutex  ||= Mutex.new

          full = false
          @mutex.synchronize do
            @buffer << event
            full = @buffer.size >= batch_size
          end

          flush if full
        end

        def deliver(transport, batch)
          if transport.respond_to?(:ship_batch)
            transport.ship_batch(batch)
          else
            batch.all? { |event| transport.ship(event) }
          end
        rescue StandardError => e
          Legion::Logging.error("Shipper deliver failed: #{e.message}") if defined?(Legion::Logging)
          false
        end

        def shippable_level?(level)
          return true if level.nil?

          min = minimum_level
          LEVEL_ORDER.index(level.to_s.downcase).to_i >= LEVEL_ORDER.index(min).to_i
        end

        def transport_type
          return :file unless defined?(Legion::Settings)

          key = Legion::Settings.dig(:logging, :shipper, :transport)
          key ? key.to_sym : :file
        end

        def batch_size
          return 100 unless defined?(Legion::Settings)

          Legion::Settings.dig(:logging, :shipper, :batch_size) || 100
        end

        def flush_interval
          return 5 unless defined?(Legion::Settings)

          Legion::Settings.dig(:logging, :shipper, :flush_interval) || 5
        end

        def minimum_level
          return 'warn' unless defined?(Legion::Settings)

          levels = Legion::Settings.dig(:logging, :shipper, :levels)
          return 'warn' unless levels.is_a?(Array) && !levels.empty?

          levels.min_by { |l| LEVEL_ORDER.index(l.to_s) || 99 }.to_s
        end
      end
    end
  end
end
