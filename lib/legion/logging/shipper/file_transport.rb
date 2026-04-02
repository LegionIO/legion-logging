# frozen_string_literal: true

require 'fileutils'
require 'json'

module Legion
  module Logging
    module Shipper
      module FileTransport
        DEFAULT_PATH = '/var/log/legion/siem.log'

        class << self
          def ship(event)
            ship_batch([event])
          end

          def ship_batch(events)
            batch = Array(events)
            return true if batch.empty?

            path = resolve_path
            FileUtils.mkdir_p(File.dirname(path))
            File.open(path, 'a') do |f|
              f.write(batch.map { |event| ::JSON.generate(event) }.join("\n"))
              f.write("\n")
            end
            true
          rescue StandardError => e
            Legion::Logging.error("FileTransport ship failed: #{e.message}") if defined?(Legion::Logging)
            false
          end

          private

          def resolve_path
            return settings_path if settings_path

            DEFAULT_PATH
          end

          def settings_path
            return nil unless defined?(Legion::Settings)

            Legion::Settings.dig(:logging, :shipper, :file, :path)
          end
        end
      end
    end
  end
end
