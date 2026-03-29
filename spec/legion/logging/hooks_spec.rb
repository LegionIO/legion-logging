# frozen_string_literal: true

require 'spec_helper'
require 'legion/logging/hooks'

RSpec.describe Legion::Logging::Hooks do
  before { described_class.clear_hooks! }
  after  do
    described_class.disable_hooks!
    described_class.clear_hooks!
  end

  describe '.on_warn / .on_error / .on_fatal' do
    it 'registers a warn callback' do
      called = false
      described_class.on_warn { |_msg, _event| called = true }
      described_class.enable_hooks!
      described_class.fire(:warn, 'test', { level: :warn })
      expect(called).to be true
    end

    it 'registers an error callback' do
      called = false
      described_class.on_error { |_msg, _event| called = true }
      described_class.enable_hooks!
      described_class.fire(:error, 'test', { level: :error })
      expect(called).to be true
    end

    it 'registers a fatal callback' do
      called = false
      described_class.on_fatal { |_msg, _event| called = true }
      described_class.enable_hooks!
      described_class.fire(:fatal, 'test', { level: :fatal })
      expect(called).to be true
    end
  end

  describe '.fire' do
    it 'calls hooks with message and event arguments' do
      captured_msg = nil
      captured_event = nil
      described_class.on_error do |msg, event|
        captured_msg = msg
        captured_event = event
      end
      described_class.enable_hooks!
      described_class.fire(:error, 'boom', { level: :error, timestamp: '2026-01-01' })
      expect(captured_msg).to eq('boom')
      expect(captured_event).to eq({ level: :error, timestamp: '2026-01-01' })
    end

    it 'does not fire when hooks are disabled' do
      called = false
      described_class.on_error { |_msg, _event| called = true }
      described_class.disable_hooks!
      described_class.fire(:error, 'test', {})
      expect(called).to be false
    end

    it 'does not fire hooks for non-matching levels' do
      called = false
      described_class.on_warn { |_msg, _event| called = true }
      described_class.enable_hooks!
      described_class.fire(:error, 'test', {})
      expect(called).to be false
    end

    it 'rescues callback errors silently' do
      described_class.on_error { |_msg, _event| raise 'kaboom' }
      described_class.enable_hooks!
      expect { described_class.fire(:error, 'test', {}) }.not_to raise_error
    end

    it 'fires multiple callbacks for the same level' do
      results = []
      described_class.on_warn { |msg, _event| results << "a:#{msg}" }
      described_class.on_warn { |msg, _event| results << "b:#{msg}" }
      described_class.enable_hooks!
      described_class.fire(:warn, 'hi', {})
      expect(results).to eq(%w[a:hi b:hi])
    end

    it 'ignores unknown levels' do
      called = false
      described_class.on_warn { |_msg, _event| called = true }
      described_class.enable_hooks!
      described_class.fire(:info, 'test', {})
      expect(called).to be false
    end
  end

  describe '.enable_hooks! / .disable_hooks! / .enabled?' do
    it 'defaults to disabled' do
      expect(described_class.enabled?).to be false
    end

    it 'can be enabled' do
      described_class.enable_hooks!
      expect(described_class.enabled?).to be true
    end

    it 'can be disabled after enabling' do
      described_class.enable_hooks!
      described_class.disable_hooks!
      expect(described_class.enabled?).to be false
    end
  end

  describe '.clear_hooks!' do
    it 'removes all registered hooks' do
      called = false
      described_class.on_error { |_msg, _event| called = true }
      described_class.clear_hooks!
      described_class.enable_hooks!
      described_class.fire(:error, 'test', {})
      expect(called).to be false
    end
  end

  describe 'delegate methods on Legion::Logging' do
    it 'delegates on_fatal' do
      called = false
      Legion::Logging.on_fatal { |_msg, _event| called = true }
      described_class.enable_hooks!
      described_class.fire(:fatal, 'test', {})
      expect(called).to be true
    end

    it 'delegates on_error' do
      called = false
      Legion::Logging.on_error { |_msg, _event| called = true }
      described_class.enable_hooks!
      described_class.fire(:error, 'test', {})
      expect(called).to be true
    end

    it 'delegates on_warn' do
      called = false
      Legion::Logging.on_warn { |_msg, _event| called = true }
      described_class.enable_hooks!
      described_class.fire(:warn, 'test', {})
      expect(called).to be true
    end

    it 'delegates enable_hooks!' do
      Legion::Logging.enable_hooks!
      expect(described_class.enabled?).to be true
    end

    it 'delegates disable_hooks!' do
      described_class.enable_hooks!
      Legion::Logging.disable_hooks!
      expect(described_class.enabled?).to be false
    end

    it 'delegates clear_hooks!' do
      called = false
      described_class.on_error { |_msg, _event| called = true }
      Legion::Logging.clear_hooks!
      described_class.enable_hooks!
      described_class.fire(:error, 'test', {})
      expect(called).to be false
    end
  end

  describe 'integration with Methods' do
    before do
      Legion::Logging.setup(level: 'debug', async: false)
      described_class.clear_hooks!
      described_class.enable_hooks!
    end

    after do
      described_class.disable_hooks!
      described_class.clear_hooks!
    end

    it 'fires on_warn hooks when warn is called' do
      captured = nil
      described_class.on_warn { |msg, event| captured = { msg: msg, event: event } }
      Legion::Logging.warn('hook warn test')
      expect(captured).not_to be_nil
      expect(captured[:msg]).to eq('hook warn test')
      expect(captured[:event]).to be_a(Hash)
      expect(captured[:event][:level]).to eq(:warn)
    end

    it 'fires on_error hooks when error is called' do
      captured = nil
      described_class.on_error { |msg, event| captured = { msg: msg, event: event } }
      Legion::Logging.error('hook error test')
      expect(captured).not_to be_nil
      expect(captured[:msg]).to eq('hook error test')
      expect(captured[:event][:level]).to eq(:error)
    end

    it 'fires on_fatal hooks when fatal is called' do
      captured = nil
      described_class.on_fatal { |msg, event| captured = { msg: msg, event: event } }
      Legion::Logging.fatal('hook fatal test')
      expect(captured).not_to be_nil
      expect(captured[:msg]).to eq('hook fatal test')
      expect(captured[:event][:level]).to eq(:fatal)
    end

    it 'does not fire hooks when disabled' do
      called = false
      described_class.on_error { |_msg, _event| called = true }
      described_class.disable_hooks!
      Legion::Logging.error('should not fire')
      expect(called).to be false
    end
  end
end
