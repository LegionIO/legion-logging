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
          "#{::JSON.generate(entry)}\n"
        rescue StandardError => e
          warn("Legion::Logging::Builder#json_format formatter failed: #{e.message}")
          "{\"timestamp\":\"#{datetime}\",\"level\":\"#{severity}\",\"message\":#{msg.to_s.dump}}\n"
        end
      end

      def text_format(include_pid: false, **options)
        log.formatter = proc do |severity, datetime, _progname, msg|
          options[:lex_name] = if options.key?(:lex_segments)
                                 options[:lex_segments].map { |s| "[#{s}]" }.join
                               elsif options.key?(:lex) && !options[:lex].nil?
                                 "[#{options[:lex]}]"
                               end
          unless options[:lex_name].nil?
            loc  = caller_locations[4]
            path = loc.to_s.split('/').last(2)
            runner_trace = {
              type:        path[0],
              file:        File.basename(loc.path, '.*'),
              function:    loc.base_label,
              line_number: loc.lineno
            }
          end
          string = "[#{datetime}]"
          string.concat("[#{::Process.pid}]") if include_pid
          string.concat(options[:lex_name]) unless options[:lex_name].nil?
          if runner_trace.is_a?(Hash) && (options[:extended] || severity == 'debug')
            string.concat("[#{runner_trace[:type]}:#{runner_trace[:file]}:#{runner_trace[:function]}:#{runner_trace[:line_number]}]")
          end
          string.concat(" #{severity} #{msg}\n")
          string
        end
      end

      def output(**options)
        if options[:log_file] && options[:log_stdout] != false
          path = prepare_log_path(options[:log_file])
          require_relative 'multi_io'
          io = MultiIO.new($stdout, File.open(path, 'a'))
          @log = ::Logger.new(io)
        elsif options[:log_file]
          @log = ::Logger.new(prepare_log_path(options[:log_file]))
        else
          @log = ::Logger.new($stdout)
        end
      end

      def log
        @log ||= set_log
      end

      def set_log(logfile: nil, log_stdout: nil, **)
        if logfile && log_stdout != false
          path = prepare_log_path(logfile)
          require_relative 'multi_io'
          io = MultiIO.new($stdout, File.open(path, 'a'))
          @log = ::Logger.new(io)
        elsif logfile
          @log = ::Logger.new(prepare_log_path(logfile))
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

      def log_level(level = 'info')
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
                        0
                      end
                    end
        @log = log
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
        @async_writer&.stop
        @async = false
      end
    end
  end
end
