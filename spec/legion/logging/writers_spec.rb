# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Legion::Logging writers' do
  before do
    Legion::Logging.log_writer = nil
    Legion::Logging.exception_writer = nil
  end

  describe '.log_writer' do
    it 'defaults to a no-op lambda' do
      expect(Legion::Logging.log_writer).to respond_to(:call)
    end

    it 'can be set to a custom writer' do
      captured = []
      Legion::Logging.log_writer = ->(event, routing_key:, headers: nil, properties: nil) { captured << { event: event, routing_key: routing_key, headers: headers, properties: properties } }
      Legion::Logging.log_writer.call({ level: :error }, routing_key: 'test', headers: { 'x-level' => 'error' }, properties: { app_id: 'legionio' })
      expect(captured.size).to eq(1)
      expect(captured.first[:headers]).to eq({ 'x-level' => 'error' })
    end

    it 'resets to no-op when set to nil' do
      Legion::Logging.log_writer = ->(_e, routing_key:, headers: nil, properties: nil) {}
      Legion::Logging.log_writer = nil
      expect { Legion::Logging.log_writer.call({}, routing_key: 'x') }.not_to raise_error
    end

    it 'builds log headers with protocol, Legion version, and identity headers' do
      stub_const('Legion::VERSION', '1.9.99')
      stub_const('Legion::Identity::Process', Class.new do
        def self.resolved? = true

        def self.identity_hash
          {
            canonical_name:  'agent.local',
            trust:           'local',
            id:              'ident-123',
            kind:            'process',
            mode:            'service',
            source:          'lex-identity-system',
            db_principal_id: 42,
            db_identity_id:  99
          }
        end
      end)

      headers = Legion::Logging.send(:build_log_headers, { lex: 'agentic-memory', node: 'node-1' }, 'helper', :error)

      expect(headers).to include(
        'legion_protocol_version'           => '2.0',
        'x-legion-version'                  => '1.9.99',
        'x-legion-identity-canonical-name'  => 'agent.local',
        'x-legion-identity-trust'           => 'local',
        'x-legion-identity-id'              => 'ident-123',
        'x-legion-identity-kind'            => 'process',
        'x-legion-identity-mode'            => 'service',
        'x-legion-identity-source'          => 'lex-identity-system',
        'x-legion-identity-db-principal-id' => 42,
        'x-legion-identity-db-identity-id'  => 99
      )
    end
  end

  describe '.exception_writer' do
    it 'defaults to a no-op lambda' do
      expect(Legion::Logging.exception_writer).to respond_to(:call)
    end

    it 'receives event, routing_key, headers, and properties' do
      captured = nil
      Legion::Logging.exception_writer = lambda { |event, routing_key:, headers:, properties:|
        captured = { event: event, routing_key: routing_key, headers: headers, properties: properties }
      }
      Legion::Logging.exception_writer.call(
        { test: true },
        routing_key: 'legion.logging.exception.error.eval.transport',
        headers:     { 'x-error-fingerprint' => 'abc' },
        properties:  { content_type: 'application/json' }
      )
      expect(captured[:routing_key]).to eq('legion.logging.exception.error.eval.transport')
      expect(captured[:headers]['x-error-fingerprint']).to eq('abc')
    end
  end
end
