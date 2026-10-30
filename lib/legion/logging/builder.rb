# frozen_string_literal: true

require 'fileutils'
require 'monitor'
require_relative 'output_logger'
require_relative 'rotation'

module Legion
  module Logging
    module Builder
      LIFECYCLE_MUTEX = Mutex.new
      private_constant :LIFECYCLE_MUTEX

      def log_format(format: :text, include_pid: false, **)
        @format = format.to_sym
        if @format == :json
          json_format(include_pid: include_pid)
        else
          text_format(include_pid: include_pid, **)
        end
      end

      def json?
        @format == :json
      end

      def json_format(include_pid: false)
        log.formatter = proc do |severity, datetime, _progname, msg|
          origin = Thread.current[:legion_log_origin]
          if origin
            timestamp = origin[:timestamp]
            thread_id = origin[:thread]
          else
            timestamp = datetime.utc
            thread_id = Thread.current.object_id
          end
          entry = {
            timestamp: timestamp.iso8601(3),
            level:     severity.downcase,
            message:   msg.is_a?(String) ? msg.gsub(/\e\[[0-9;]*m/, '') : msg.to_s,
            thread:    thread_id
          }
          entry[:pid] = ::Process.pid if include_pid
          segments = Thread.current[:legion_log_segments]
          entry[:segments] = segments if segments
          method_ctx = Thread.current[:legion_log_method]
          entry[:method] = method_ctx if method_ctx
          conv_id = Thread.current[:legion_log_conv_id]
          entry[:conversation_id] = conv_id if conv_id.is_a?(String) && !conv_id.empty?
          request_id = Thread.current[:legion_log_request_id]
          entry[:request_id] = request_id if request_id.is_a?(String) && !request_id.empty?
          exchange_id = Thread.current[:legion_log_exchange_id]
          entry[:exchange_id] = exchange_id if exchange_id.is_a?(String) && !exchange_id.empty?
          chain_id = Thread.current[:legion_log_chain_id]
          entry[:chain_id] = chain_id if chain_id.is_a?(String) && !chain_id.empty?
          "#{::JSON.generate(entry)}\n"
        rescue StandardError => e
          warn("Legion::Logging::Builder#json_format formatter failed: #{e.message}")
          "{\"timestamp\":\"#{datetime}\",\"level\":\"#{severity}\",\"message\":#{msg.to_s.dump}}\n"
        end
      end

      def text_format(include_pid: false, **options)
        log.formatter = proc do |severity, datetime, _progname, msg|
          datetime = Thread.current[:legion_log_origin]&.[](:timestamp)&.getlocal || datetime
          lex_name = resolve_lex_tag(options)
          runner_trace = Thread.current[:legion_log_caller] || build_runner_trace if lex_name

          string = "[#{datetime}]"
          string.concat("[#{::Process.pid}]") if include_pid
          string.concat(lex_name) if lex_name
          if runner_trace.is_a?(Hash) && (options[:extended] || severity == 'debug')
            string.concat("[#{runner_trace[:type]}:#{runner_trace[:file]}:#{runner_trace[:function]}:#{runner_trace[:line_number]}]")
          end
          ctx_pairs = build_context_kv_pairs
          if ctx_pairs.empty?
            string.concat(" #{severity} #{msg}\n")
          else
            string.concat(" #{severity} #{msg} #{ctx_pairs}\n")
          end
          string
        end
      end

      def resolve_lex_tag(options)
        segments = Thread.current[:legion_log_segments]
        tag = if segments
                segments.map { |s| "[#{s}]" }.join
              elsif options.key?(:lex_segments)
                options[:lex_segments].map { |s| "[#{s}]" }.join
              elsif options.key?(:lex) && !options[:lex].nil?
                "[#{options[:lex]}]"
              end

        method_ctx = Thread.current[:legion_log_method]
        tag = "#{tag}{#{method_ctx}}" if tag && method_ctx

        context_id = Thread.current[:legion_log_conv_id]
        tag = "#{tag}{#{context_id}}" if tag && context_id.is_a?(String) && !context_id.empty?
        tag
      end

      def build_context_kv_pairs
        pairs = []
        request_id = Thread.current[:legion_log_request_id]
        pairs << "request_id=#{request_id}" if request_id.is_a?(String) && !request_id.empty?
        exchange_id = Thread.current[:legion_log_exchange_id]
        pairs << "exchange_id=#{exchange_id}" if exchange_id.is_a?(String) && !exchange_id.empty?
        chain_id = Thread.current[:legion_log_chain_id]
        pairs << "chain_id=#{chain_id}" if chain_id.is_a?(String) && !chain_id.empty?
        pairs.join(' ')
      end

      def build_runner_trace(loc = caller_locations(6, 1)&.first)
        return unless loc

        path = loc.to_s.split('/').last(2)
        {
          type:        path[0],
          file:        File.basename(loc.path, '.*'),
          function:    loc.base_label,
          line_number: loc.lineno
        }
      end

      def output(**options)
        set_log(logfile: options[:log_file], log_stdout: options[:log_stdout], rotation: options[:rotation])
      end

      def log
        @log ||= set_log
      end

      # A nil rotation option reads loaded Settings; false disables rotation.
      def set_log(logfile: nil, log_stdout: nil, rotation: nil, **)
        with_lifecycle_lock do
          return false if @async_writer && stop_async_writer == false

          previous_log = @log
          rotation_opts = Legion::Logging::Rotation.resolve(raw: rotation.nil? ? Legion::Logging::Rotation.from_settings : rotation)

          if logfile && log_stdout != false
            require_relative 'multi_io'
            io = Legion::Logging::MultiIO.new(stdout_target(rotation_opts: rotation_opts),
                                              open_log_file(path: prepare_log_path(logfile), rotation_opts: rotation_opts))
            @log = Legion::Logging::OutputLogger.new(io)
          elsif logfile
            @log = Legion::Logging::OutputLogger.new(open_log_file(path: prepare_log_path(logfile), rotation_opts: rotation_opts))
          else
            @log = Legion::Logging::OutputLogger.new(stdout_target(rotation_opts: rotation_opts))
          end

          @log.async_writer = @async_writer
          close_replaced_log(previous_log)
          @log
        end
      end

      def prepare_log_path(path)
        expanded = File.expand_path(path)
        FileUtils.mkdir_p(File.dirname(expanded))
        expanded
      end

      def level
        log.level
      end

      def log_level(level = 'debug')
        log.level = case level
                    when 'trace', 'debug'
                      ::Logger::DEBUG
                    when 'info'
                      ::Logger::INFO
                    when 'warn'
                      ::Logger::WARN
                    when 'error'
                      ::Logger::ERROR
                    when 'fatal'
                      ::Logger::FATAL
                    when nil
                      42
                    else
                      if level.is_a? Integer
                        level
                      else
                        1
                      end
                    end
      end

      def async?
        (@async == true && @async_writer&.alive?) || false
      end

      def start_async_writer(buffer_size: 10_000, timeout: 2)
        with_lifecycle_lock do
          require_relative 'async_writer'
          return false if @async_writer && stop_async_writer(timeout: timeout) == false

          @async_writer = AsyncWriter.new(log, buffer_size: buffer_size)
          log.async_writer = @async_writer
          @async_writer.start
          @async = true
          true
        end
      end

      def stop_async_writer(timeout: 2)
        with_lifecycle_lock do
          return true unless @async_writer

          @async_writer.stop(timeout: timeout)
        end
      end

      private

      def open_log_file(path:, rotation_opts:)
        if rotation_opts[:enabled]
          return Legion::Logging::RotatingFile.new(path: path, max_bytes: rotation_opts[:max_bytes], max_files: rotation_opts[:max_files])
        end

        file = File.new(path, 'a')
        file.sync = true
        file
      end

      # Keep redirected stderr eligible even when stdout is a pipe or terminal.
      def stdout_target(rotation_opts:)
        return $stdout unless rotation_opts[:enabled] && rotation_opts[:stdio]
        return $stdout unless Legion::Logging::Rotation.regular_file_path(io: $stdout) || Legion::Logging::Rotation.regular_file_path(io: $stderr)

        Legion::Logging::StdioRotator.shared(max_bytes: rotation_opts[:max_bytes], max_files: rotation_opts[:max_files])
      end

      def with_lifecycle_lock
        lock = LIFECYCLE_MUTEX.synchronize { @lifecycle_lock ||= Monitor.new }
        entered = lock.try_enter
        return false unless entered

        yield
      ensure
        lock.exit if entered
      end

      def close_replaced_log(logger)
        return unless logger
        return if logger.equal?(@log)
        return if @async_writer&.alive? && @async_writer.respond_to?(:logger) && @async_writer.logger.equal?(logger)

        log_device = logger.instance_variable_get(:@logdev)
        dev = log_device&.dev
        return if dev.nil? || [$stdout, $stderr].include?(dev)

        dev.close if dev.respond_to?(:close)
      end
    end
  end
end
