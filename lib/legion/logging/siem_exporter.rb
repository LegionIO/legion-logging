# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'

module Legion
  module Logging
    module SIEMExporter
      PHI_PATTERNS = [
        [/\b\d{3}-\d{2}-\d{4}\b/, '[SSN-REDACTED]'],
        [/\b\d{3}-\d{3}-\d{4}\b/, '[PHONE-REDACTED]'],
        [/\b[A-Z]{2}\d{7}\b/, '[MRN-REDACTED]'],
        [%r{\b\d{2}/\d{2}/\d{4}\b}, '[DOB-REDACTED]']
      ].freeze

      class << self
        def redact_phi(text)
          result = text.to_s.dup
          PHI_PATTERNS.each { |pattern, replacement| result.gsub!(pattern, replacement) }
          result
        end

        def export_to_splunk(event, hec_url:, token:)
          uri = URI(hec_url)
          req = Net::HTTP::Post.new(uri)
          req['Authorization'] = "Splunk #{token}"
          req['Content-Type'] = 'application/json'
          req.body = ::JSON.dump({ event: redact_phi(event.to_s), time: Time.now.to_f })

          Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https') do |http|
            http.request(req)
          end
        rescue StandardError => e
          warn("Legion::Logging::SIEMExporter#export_to_splunk failed: #{e.message}")
          { error: e.message }
        end

        def format_for_elk(event, index: 'legion')
          {
            '@timestamp' => Time.now.utc.iso8601,
            'index'      => index,
            'message'    => redact_phi(event.to_s),
            'source'     => 'legion'
          }
        end
      end
    end
  end
end
