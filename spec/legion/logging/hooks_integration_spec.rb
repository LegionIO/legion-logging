# frozen_string_literal: true

require 'legion/logging'

RSpec.describe 'Logging hooks integration' do
  let(:logger) { Legion::Logging::Logger.new(level: 'debug', lex: 'slack', async: false) }
  let(:received_events) { [] }

  before do
    Legion::Logging.clear_hooks!
    Legion::Logging.enable_hooks!
  end

  after do
    Legion::Logging.disable_hooks!
    Legion::Logging.clear_hooks!
  end

  describe 'singleton logger' do
    it 'fires fatal hooks' do
      Legion::Logging.on_fatal { |event| received_events << event }
      Legion::Logging.fatal('fatal message')
      expect(received_events.size).to eq(1)
      expect(received_events.first[:level]).to eq(:fatal)
      expect(received_events.first[:lex]).to be_nil
    end

    it 'fires error hooks' do
      Legion::Logging.on_error { |event| received_events << event }
      Legion::Logging.error('error message')
      expect(received_events.size).to eq(1)
      expect(received_events.first[:level]).to eq(:error)
    end

    it 'fires warn hooks' do
      Legion::Logging.on_warn { |event| received_events << event }
      Legion::Logging.warn('warn message')
      expect(received_events.size).to eq(1)
      expect(received_events.first[:level]).to eq(:warn)
    end

    it 'does not fire hooks when disabled' do
      Legion::Logging.disable_hooks!
      Legion::Logging.on_fatal { |event| received_events << event }
      Legion::Logging.fatal('should not fire')
      expect(received_events).to be_empty
    end

    it 'does not fire hooks for info' do
      Legion::Logging.on_fatal { |event| received_events << event }
      Legion::Logging.info('info message')
      expect(received_events).to be_empty
    end
  end

  describe 'per-LEX logger instance' do
    it 'fires hooks with lex context' do
      Legion::Logging.on_error { |event| received_events << event }
      logger.error('lex error')
      expect(received_events.size).to eq(1)
      expect(received_events.first[:lex]).to eq('slack')
    end
  end

  describe 'exception handling in hooks' do
    it 'does not propagate hook errors to the logger' do
      Legion::Logging.on_fatal { |_| raise 'hook exploded' }
      expect { Legion::Logging.fatal('test') }.not_to raise_error
    end

    it 'continues to other hooks when one fails' do
      Legion::Logging.on_fatal { |_| raise 'first hook exploded' }
      Legion::Logging.on_fatal { |event| received_events << event }
      Legion::Logging.fatal('test')
      expect(received_events.size).to eq(1)
    end
  end

  describe 'block-form log messages' do
    it 'fires hooks when message comes from a block' do
      Legion::Logging.on_fatal { |event| received_events << event }
      Legion::Logging.fatal { 'block message' }
      expect(received_events.size).to eq(1)
      expect(received_events.first[:message]).to include('block message')
    end
  end
end
