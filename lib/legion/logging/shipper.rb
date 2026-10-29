# frozen_string_literal: true

require_relative 'redactor'
require_relative 'shipper/file_transport'
require_relative 'shipper/http_transport'

module Legion
  module Logging
    module Shipper
      LEVEL_ORDER = %w[debug info warn error fatal].freeze
      TRANSPORTS = { file: FileTransport, http: HttpTransport }.freeze
      MUTEX = Mutex.new
      WAKE = ConditionVariable.new
      CHANGED = ConditionVariable.new
      private_constant :MUTEX, :WAKE, :CHANGED

      @buffer = []
      @accepted = 0
      @delivered = 0
      @attempt = 0
      @flush_target = 0

      class << self
        def ship(event)
          return unless enabled?
          return unless shippable_level?(event[:level] || event['level'])
          return unless TRANSPORTS.key?(transport_type)

          redacted = Redactor.redact(event)
          raise ClosedQueueError, 'log shipper is stopping' unless start

          MUTEX.synchronize do
            raise ThreadError, 'log shipper cannot enqueue from its delivery thread' if Thread.current.equal?(@flush_thread)

            CHANGED.wait(MUTEX) while !@stopping && @accepted - @delivered >= @capacity
            raise ClosedQueueError, 'log shipper is stopping' if @stopping

            @buffer << redacted
            @accepted += 1
            @flush_requested = true if @buffer.size >= @batch_size
            WAKE.signal if @flush_requested
          end
          true
        end

        def flush(timeout: 5)
          return true if MUTEX.synchronize { @accepted == @delivered }
          return false unless start

          deadline = timeout && (::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + timeout)
          MUTEX.synchronize do
            return false if Thread.current.equal?(@flush_thread)

            target = @accepted
            attempt = @attempt
            @flush_target = [@flush_target, target].max
            @flush_requested = true
            WAKE.signal
            while @delivered < target
              return false if @attempt > attempt && !@last_success
              return false unless @flush_thread&.alive?

              remaining = deadline && (deadline - ::Process.clock_gettime(::Process::CLOCK_MONOTONIC))
              return false if remaining && remaining <= 0

              CHANGED.wait(MUTEX, remaining)
            end
            true
          end
        end

        def start
          return false unless enabled?

          MUTEX.synchronize do
            return !@stopping if @flush_thread&.alive?

            @capacity = Legion::Settings.dig(:logging, :shipper, :buffer_size) || 10_000
            @batch_size = [batch_size, @capacity].min
            @interval = flush_interval
            unless @capacity.is_a?(Integer) && @capacity.positive? && @batch_size.is_a?(Integer) && @batch_size.positive? &&
                   @interval.is_a?(Numeric) && @interval.positive?
              raise ArgumentError, 'shipper buffer_size, batch_size, and flush_interval must be positive'
            end

            @transport = TRANSPORTS[transport_type]
            return false unless @transport

            @stopping = false
            @flush_requested = @buffer.size >= @batch_size
            @flush_thread = Thread.new { consume }
            @flush_thread.name = 'legion-log-shipper'
            @flush_thread.abort_on_exception = false
            true
          end
        end

        def stop(timeout: 5)
          deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + timeout if timeout
          thread = MUTEX.synchronize do
            @stopping = true
            WAKE.broadcast
            CHANGED.broadcast
            if !@flush_thread&.alive? && @accepted > @delivered
              @flush_thread = Thread.new { consume }
              @flush_thread.name = 'legion-log-shipper'
              @flush_thread.abort_on_exception = false
            end
            @flush_thread
          end
          return MUTEX.synchronize { @accepted == @delivered } unless thread
          return false if Thread.current.equal?(thread)

          remaining = [deadline - ::Process.clock_gettime(::Process::CLOCK_MONOTONIC), 0].max if deadline
          thread.join(remaining)
          MUTEX.synchronize { !thread.alive? && @accepted == @delivered }
        end

        def enabled?
          (defined?(Legion::Settings) && Legion::Settings.dig(:logging, :shipper, :enabled) == true) || false
        end

        private

        def consume
          loop do
            batch = MUTEX.synchronize do
              WAKE.wait(MUTEX, @interval) unless @flush_requested || @stopping
              @flush_requested = false
              @buffer.shift(@batch_size)
            end
            delivered = batch.empty? || deliver(@transport, batch)
            stopping = MUTEX.synchronize do
              @attempt += 1
              @last_success = delivered
              if delivered
                @delivered += batch.size
                @flush_requested = @buffer.size >= @batch_size || @delivered < @flush_target
              else
                @buffer.prepend(*batch)
              end
              CHANGED.broadcast
              @stopping && (!delivered || @buffer.empty?)
            end
            break if stopping
          end
        ensure
          MUTEX.synchronize do
            @stopping = true
            CHANGED.broadcast
          end
        end

        def deliver(transport, batch)
          transport.ship_batch(batch)
        rescue StandardError => e
          Kernel.warn("Shipper deliver failed: #{e.message}")
          false
        end

        def shippable_level?(level)
          return true if level.nil?

          LEVEL_ORDER.index(level.to_s.downcase).to_i >= LEVEL_ORDER.index(minimum_level).to_i
        end

        def transport_type
          key = Legion::Settings.dig(:logging, :shipper, :transport) if defined?(Legion::Settings)
          key ? key.to_sym : :file
        end

        def batch_size
          Legion::Settings.dig(:logging, :shipper, :batch_size) || 100
        end

        def flush_interval
          Legion::Settings.dig(:logging, :shipper, :flush_interval) || 5
        end

        def minimum_level
          levels = Legion::Settings.dig(:logging, :shipper, :levels)
          return 'warn' unless levels.is_a?(Array) && !levels.empty?

          levels.min_by { |level| LEVEL_ORDER.index(level.to_s) || 99 }.to_s
        end
      end
    end
  end
end
