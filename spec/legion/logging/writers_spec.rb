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
      Legion::Logging.log_writer = ->(event, routing_key:) { captured << { event: event, routing_key: routing_key } }
      Legion::Logging.log_writer.call({ level: :error }, routing_key: 'test')
      expect(captured.size).to eq(1)
    end

    it 'resets to no-op when set to nil' do
      Legion::Logging.log_writer = ->(_e, routing_key:) {}
      Legion::Logging.log_writer = nil
      expect { Legion::Logging.log_writer.call({}, routing_key: 'x') }.not_to raise_error
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
