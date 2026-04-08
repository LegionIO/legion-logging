# frozen_string_literal: true

module Legion
  module Logging
    module MethodTracer
      ENABLED = false
      ATTACHED = {} # rubocop:disable Style/MutableConstant
      ATTACHED_MUTEX = Mutex.new
      private_constant :ATTACHED_MUTEX

      def self.attach(base, match_singleton: false)
        return unless ENABLED

        ATTACHED_MUTEX.synchronize do
          return if ATTACHED.key?(base)

          base_name = base.to_s
          tp = TracePoint.new(:call, :return) do |trace|
            next unless trace.defined_class == base || (match_singleton && trace.defined_class == base.singleton_class)

            stack = (Thread.current[:_legion_trace_stack] ||= [])

            case trace.event
            when :call
              params = format_params(trace)
              params_segment = params.empty? ? '' : ", #{params.join(', ')}"
              indent = '  ' * stack.size
              puts "#{indent}-> #{trace.method_id}, #{base_name}#{params_segment}"
              stack.push(trace.method_id)
            when :return
              stack.pop
              indent = '  ' * stack.size
              puts "#{indent}<- #{trace.method_id}, #{base_name}"
            end
          end
          tp.enable
          ATTACHED[base] = tp
        end
      end

      def self.detach(base)
        ATTACHED_MUTEX.synchronize do
          tp = ATTACHED.delete(base)
          tp&.disable
        end
      end

      def self.detach_all
        ATTACHED_MUTEX.synchronize do
          ATTACHED.each_value(&:disable)
          ATTACHED.clear
        end
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
