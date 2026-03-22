# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'

module Legion
  module Logging
    module Shipper
      module HttpTransport
        class << self
          def ship(events)
            endpoint = resolve_endpoint
            return false unless endpoint

            uri   = URI(endpoint)
            batch = Array(events)
            body  = build_body(batch, uri)

            response = post(uri, body)
            response.is_a?(Net::HTTPSuccess)
          rescue StandardError => e
            Legion::Logging.error("HttpTransport ship failed: #{e.message}") if defined?(Legion::Logging)
            false
          end

          private

          def post(uri, body)
            req = Net::HTTP::Post.new(uri)
            req['Content-Type'] = 'application/json'
            apply_auth(req)

            Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https',
                                                     open_timeout: 5, read_timeout: 10) do |http|
              http.request(req, body)
            end
          end

          def build_body(events, uri)
            # Splunk HEC expects { event: ... } per event; others expect an array
            if splunk_hec?(uri)
              events.map { |e| ::JSON.generate({ event: e, time: Time.now.to_f }) }.join("\n")
            else
              ::JSON.generate(events)
            end
          end

          def splunk_hec?(uri)
            uri.path.include?('/services/collector')
          end

          def apply_auth(req)
            token = auth_token
            return unless token

            req['Authorization'] = if splunk_hec?(URI(req.path.empty? ? '/' : req.uri&.to_s || '/'))
                                     "Splunk #{token}"
                                   else
                                     "Bearer #{token}"
                                   end
          end

          def auth_token
            return nil unless defined?(Legion::Settings)

            Legion::Settings.dig(:logging, :shipper, :auth_token)
          end

          def resolve_endpoint
            return nil unless defined?(Legion::Settings)

            Legion::Settings.dig(:logging, :shipper, :endpoint)
          end
        end
      end
    end
  end
end
