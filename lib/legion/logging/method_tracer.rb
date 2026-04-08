# frozen_string_literal: true

module Legion
  module Logging
    module MethodTracer
      ENABLED = false

      def self.attach(base, match_singleton: false)
        return unless ENABLED

        base_name = base.to_s
        TracePoint.new(:call, :return) do |tp|
          next unless tp.defined_class == base || (match_singleton && tp.defined_class == base.singleton_class)

          stack = (Thread.current[:_legion_trace_stack] ||= [])

          case tp.event
          when :call
            params = format_params(tp)
            indent = '  ' * stack.size
            puts "#{indent}-> #{tp.method_id}, #{base_name}, #{params.join(', ')}"
            stack.push(tp.method_id)
          when :return
            stack.pop
            indent = '  ' * stack.size
            puts "#{indent}<- #{tp.method_id}, #{base_name}"
          end
        end.enable
      end

      def self.format_params(trace_point)
        trace_point.parameters.filter_map do |type, name|
          next unless name

          val = begin
            trace_point.binding.local_variable_get(name)
          rescue StandardError
            '?'
          end
          case type
          when :req, :opt then "#{name}=#{val.inspect}"
          when :keyreq, :key then "#{name}: #{val.inspect}"
          when :rest then "*#{name}"
          when :keyrest then "**#{name}"
          end
        end
      end
    end
  end
end
