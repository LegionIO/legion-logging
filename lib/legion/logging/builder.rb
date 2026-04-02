# frozen_string_literal: true

require 'fileutils'

module Legion
  module Logging
    module Builder
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
          entry = {
            timestamp: datetime.utc.iso8601(3),
            level:     severity.downcase,
            message:   msg.is_a?(String) ? msg.gsub(/\e\[[0-9;]*m/, '') : msg.to_s,
            thread:    Thread.current.object_id
          }
          entry[:pid] = ::Process.pid if include_pid
          segments = Thread.current[:legion_log_segments]
          entry[:segments] = segments if segments
          method_ctx = Thread.current[:legion_log_method]
          entry[:method] = method_ctx if method_ctx
          "#{::JSON.generate(entry)}\n"
        rescue StandardError => e
          warn("Legion::Logging::Builder#json_format formatter failed: #{e.message}")
          "{\"timestamp\":\"#{datetime}\",\"level\":\"#{severity}\",\"message\":#{msg.to_s.dump}}\n"
        end
      end

      def text_format(include_pid: false, **options)
        log.formatter = proc do |severity, datetime, _progname, msg|
          lex_name = resolve_lex_tag(options)
          runner_trace = Thread.current[:legion_log_caller] || build_runner_trace if lex_name

          string = "[#{datetime}]"
          string.concat("[#{::Process.pid}]") if include_pid
          string.concat(lex_name) if lex_name
          if runner_trace.is_a?(Hash) && (options[:extended] || severity == 'debug')
            string.concat("[#{runner_trace[:type]}:#{runner_trace[:file]}:#{runner_trace[:function]}:#{runner_trace[:line_number]}]")
          end
          string.concat(" #{severity} #{msg}\n")
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
        tag
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
        set_log(logfile: options[:log_file], log_stdout: options[:log_stdout])
      end

      def log
        @log ||= set_log
      end

      def set_log(logfile: nil, log_stdout: nil, **)
        if logfile && log_stdout != false
          path = prepare_log_path(logfile)
          require_relative 'multi_io'
          file = File.new(path, 'a')
          file.sync = true
          io = MultiIO.new($stdout, file)
          @log = ::Logger.new(io)
        elsif logfile
          file = File.new(prepare_log_path(logfile), 'a')
          file.sync = true
          @log = ::Logger.new(file)
        else
          @log = ::Logger.new($stdout)
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

      def start_async_writer(buffer_size: 10_000)
        require_relative 'async_writer'
        stop_async_writer if @async_writer&.alive?
        @async_writer = AsyncWriter.new(log, buffer_size: buffer_size)
        @async_writer.start
        @async = true
      end

      def stop_async_writer
        writer = @async_writer
        writer&.stop
        @async_writer = nil if @async_writer.equal?(writer)
        @async = false
      end
    end
  end
end
