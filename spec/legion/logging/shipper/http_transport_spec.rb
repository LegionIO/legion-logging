# frozen_string_literal: true

require 'spec_helper'
require 'legion/logging/shipper/http_transport'

RSpec.describe Legion::Logging::Shipper::HttpTransport do
  describe '.ship' do
    let(:endpoint) { 'http://localhost:9200/logs' }
    let(:events)   { [{ level: 'error', message: 'test event' }] }

    before do
      stub_const('Legion::Settings', Module.new)
      allow(Legion::Settings).to receive(:[]).and_return(nil)
      allow(Legion::Settings).to receive(:dig).and_return(nil)
      allow(Legion::Settings).to receive(:dig).with(:logging, :shipper, :endpoint).and_return(endpoint)
      allow(Legion::Settings).to receive(:dig).with(:logging, :shipper, :auth_token).and_return(nil)
    end

    it 'returns false when no endpoint is configured' do
      allow(Legion::Settings).to receive(:dig).with(:logging, :shipper, :endpoint).and_return(nil)
      expect(described_class.ship(events)).to be(false)
    end

    it 'returns false when Legion::Settings is not defined' do
      hide_const('Legion::Settings') if defined?(Legion::Settings)
      expect(described_class.ship(events)).to be(false)
    end

    it 'does not initialize unloaded settings to discover an endpoint' do
      initialized = false
      allow(Legion::Settings).to receive(:loaded?).and_return(false)
      allow(Legion::Settings).to receive(:dig).with(:logging, :shipper, :endpoint) do
        initialized = true
        nil
      end

      expect(described_class.ship(events)).to be(false)
      expect(initialized).to be(false)
    end

    it 'POSTs a JSON body to the endpoint' do
      response = instance_double(Net::HTTPSuccess, is_a?: true)
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)

      http = instance_double(Net::HTTP)
      allow(Net::HTTP).to receive(:start).and_yield(http)
      allow(http).to receive(:request).and_return(response)

      result = described_class.ship(events)
      expect(result).to be(true)
    end

    it 'reports a network failure locally without feeding it back into log forwarding' do
      forwarded = []
      Legion::Logging.setup(level: 'debug', log_file: File::NULL, log_stdout: false, async: false)
      Legion::Logging.log_writer = ->(event, **) { forwarded << event }
      allow(Net::HTTP).to receive(:start).and_raise(Errno::ECONNREFUSED)

      result = nil
      expect { result = described_class.ship(events) }.to output(/Connection refused/i).to_stderr
      expect(result).to be(false)
      expect(forwarded).to be_empty
    ensure
      Legion::Logging.log_writer = nil
    end

    it 'sets Content-Type to application/json' do
      req_captured = nil
      http = instance_double(Net::HTTP)
      allow(Net::HTTP).to receive(:start).and_yield(http)
      allow(http).to receive(:request) do |req, _body|
        req_captured = req
        instance_double(Net::HTTPOK, is_a?: true).tap do |r|
          allow(r).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
        end
      end

      described_class.ship(events)
      expect(req_captured['Content-Type']).to eq('application/json')
    end

    context 'with a Splunk HEC endpoint' do
      let(:endpoint) { 'https://splunk:8088/services/collector/event' }

      it 'wraps events in Splunk HEC format' do
        body_captured = nil
        http = instance_double(Net::HTTP)
        allow(Net::HTTP).to receive(:start).and_yield(http)
        allow(http).to receive(:request) do |_req, body|
          body_captured = body
          instance_double(Net::HTTPOK, is_a?: true).tap do |r|
            allow(r).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
          end
        end

        described_class.ship(events)
        expect(body_captured).to include('"event"')
        expect(body_captured).to include('"time"')
      end
    end
  end
end
