# frozen_string_literal: true

module Legion
  module Logging
    module Helper
      def log
        return @log unless @log.nil?

        logger_hash = if respond_to?(:segments)
                        { lex_segments: Array(segments) }
                      else
                        { lex: derive_log_tag }
                      end

        if respond_to?(:settings) && settings.is_a?(Hash) && settings.key?(:logger)
          ls = settings[:logger]
          logger_hash[:level] = ls[:level] if ls.key?(:level)
          logger_hash[:log_file] = ls[:log_file] if ls.key?(:log_file)
          logger_hash[:trace] = ls[:trace] if ls.key?(:trace)
          logger_hash[:extended] = ls[:extended] if ls.key?(:extended)
        end

        @log = Legion::Logging::Logger.new(**logger_hash)
      end

      private

      def derive_log_tag
        if respond_to?(:lex_filename)
          fname = lex_filename
          return fname.is_a?(Array) ? fname.first : fname
        end

        name = respond_to?(:ancestors) ? ancestors.first.to_s : self.class.to_s
        parts = name.split('::')
        ext_idx = parts.index('Extensions')
        target = if ext_idx && parts[ext_idx + 1]
                   parts[ext_idx + 1]
                 else
                   parts.last
                 end
        target.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
              .gsub(/([a-z\d])([A-Z])/, '\1_\2')
              .downcase
      end
    end
  end
end
