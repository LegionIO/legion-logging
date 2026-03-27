# frozen_string_literal: true

require 'spec_helper'
require 'legion/logging/async_writer'

RSpec.describe Legion::Logging::AsyncWriter do
  let(:logger) { Logger.new($stdout) }

  after { subject.stop if subject.alive? }

  describe '#start / #stop lifecycle' do
    subject { described_class.new(logger) }

    it 'starts a writer thread' do
      subject.start
      expect(subject.alive?).to be true
    end

    it 'stops the writer thread cleanly' do
      subject.start
      subject.stop
      expect(subject.alive?).to be false
    end

    it 'is safe to stop when not started' do
      expect { subject.stop }.not_to raise_error
    end

    it 'is safe to start twice' do
      subject.start
      thread = subject.instance_variable_get(:@thread)
      subject.start
      expect(subject.instance_variable_get(:@thread)).to equal(thread)
    end
  end

  describe '#push' do
    subject { described_class.new(logger) }

    before { subject.start }

    it 'writes entries to the logger' do
      entry = Legion::Logging::AsyncWriter::LogEntry.new(
        level: :info, message: 'async test', writer_context: nil
      )
      subject.push(entry)
      subject.stop
    end

    it 'writes multiple entries in order' do
      messages = []
      allow(logger).to receive(:info) { |msg| messages << msg }

      3.times { |i| subject.push(Legion::Logging::AsyncWriter::LogEntry.new(level: :info, message: "msg-#{i}", writer_context: nil)) }
      subject.stop

      expect(messages).to eq(%w[msg-0 msg-1 msg-2])
    end
  end

  describe 'back-pressure' do
    subject { described_class.new(logger, buffer_size: 2) }

    it 'blocks the caller when the queue is full' do
      2.times { |i| subject.push(Legion::Logging::AsyncWriter::LogEntry.new(level: :info, message: "fill-#{i}", writer_context: nil)) }

      blocked = true
      pusher = Thread.new do
        subject.push(Legion::Logging::AsyncWriter::LogEntry.new(level: :info, message: 'overflow', writer_context: nil))
        blocked = false
      end

      deadline = Time.now + 2
      sleep 0.05 until pusher.status == 'sleep' || Time.now > deadline
      expect(blocked).to be true
      pusher.kill
      pusher.join(1)
    end
  end

  describe 'shutdown drain' do
    subject { described_class.new(logger) }

    it 'drains remaining entries on stop' do
      messages = []
      allow(logger).to receive(:warn) { |msg| messages << msg }

      subject.start
      5.times { |i| subject.push(Legion::Logging::AsyncWriter::LogEntry.new(level: :warn, message: "drain-#{i}", writer_context: nil)) }
      subject.stop

      expect(messages).to eq((0..4).map { |i| "drain-#{i}" })
    end
  end

  describe 'writer context' do
    subject { described_class.new(logger) }

    before { subject.start }

    it 'calls log_writer when writer_context is present' do
      captured = nil
      Legion::Logging.log_writer = lambda { |event, routing_key:|
        captured = { event: event, routing_key: routing_key }
      }

      event = { level: :error, message: 'writer test', lex: 'core' }
      entry = Legion::Logging::AsyncWriter::LogEntry.new(
        level: :error, message: 'writer test',
        writer_context: { level: :error, event: event }
      )
      subject.push(entry)
      sleep 0.1
      expect(captured).not_to be_nil
      expect(captured[:event][:message]).to eq('writer test')

      Legion::Logging.log_writer = nil
    end
  end

  describe 'LogEntry' do
    subject { described_class.new(logger) }

    it 'is a frozen Data struct' do
      entry = Legion::Logging::AsyncWriter::LogEntry.new(level: :info, message: 'test', writer_context: nil)
      expect(entry).to be_frozen
    end
  end
end

RSpec.describe 'Legion::Logging::Logger instance async' do
  it 'supports async: true in constructor' do
    logger = Legion::Logging::Logger.new(level: 'info', async: true)
    expect(logger.async?).to be true
    logger.stop_async_writer
  end

  it 'defaults to sync when async not specified' do
    logger = Legion::Logging::Logger.new(level: 'info')
    expect(logger.async?).to be false
  end
end

RSpec.describe 'async routing through Methods' do
  before do
    Legion::Logging.setup(level: 'debug', async: true)
  end

  after do
    Legion::Logging.stop_async_writer
  end

  it 'routes info through the async writer' do
    writer = Legion::Logging.instance_variable_get(:@async_writer)
    expect(writer).to receive(:push).once
    Legion::Logging.info('async info')
  end

  it 'routes warn through the async writer with writer context' do
    writer = Legion::Logging.instance_variable_get(:@async_writer)
    expect(writer).to receive(:push).once
    Legion::Logging.warn('async warn')
  end

  it 'does NOT route fatal through async writer' do
    writer = Legion::Logging.instance_variable_get(:@async_writer)
    expect(writer).not_to receive(:push)
    Legion::Logging.fatal('sync fatal')
  end

  it 'falls back to sync when async is disabled' do
    Legion::Logging.stop_async_writer
    expect(Legion::Logging.log).to receive(:debug).with(anything)
    Legion::Logging.debug('sync fallback')
  end
end
