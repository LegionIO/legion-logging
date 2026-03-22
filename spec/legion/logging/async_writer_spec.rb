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
        level: :info, message: 'async test', hook_context: nil
      )
      subject.push(entry)
      subject.stop
    end

    it 'writes multiple entries in order' do
      messages = []
      allow(logger).to receive(:info) { |msg| messages << msg }

      3.times { |i| subject.push(Legion::Logging::AsyncWriter::LogEntry.new(level: :info, message: "msg-#{i}", hook_context: nil)) }
      subject.stop

      expect(messages).to eq(%w[msg-0 msg-1 msg-2])
    end
  end

  describe 'back-pressure' do
    subject { described_class.new(logger, buffer_size: 2) }

    it 'blocks the caller when the queue is full' do
      queue = subject.instance_variable_get(:@queue)
      2.times { |i| queue.push(Legion::Logging::AsyncWriter::LogEntry.new(level: :info, message: "fill-#{i}", hook_context: nil)) }

      blocked = true
      pusher = Thread.new do
        queue.push(Legion::Logging::AsyncWriter::LogEntry.new(level: :info, message: 'overflow', hook_context: nil))
        blocked = false
      end

      sleep 0.1
      expect(blocked).to be true
      pusher.kill
    end
  end

  describe 'shutdown drain' do
    subject { described_class.new(logger) }

    it 'drains remaining entries on stop' do
      messages = []
      allow(logger).to receive(:warn) { |msg| messages << msg }

      subject.start
      5.times { |i| subject.push(Legion::Logging::AsyncWriter::LogEntry.new(level: :warn, message: "drain-#{i}", hook_context: nil)) }
      subject.stop

      expect(messages).to eq((0..4).map { |i| "drain-#{i}" })
    end
  end

  describe 'hook context' do
    subject { described_class.new(logger) }

    before do
      Legion::Logging::Hooks.clear!
      Legion::Logging::Hooks.enable!
      subject.start
    end

    after do
      Legion::Logging::Hooks.disable!
      Legion::Logging::Hooks.clear!
    end

    it 'fires hooks on the writer thread' do
      fired_events = []
      Legion::Logging::Hooks.register(:error) { |event| fired_events << event }

      event = { level: :error, message: 'hook test' }
      entry = Legion::Logging::AsyncWriter::LogEntry.new(
        level: :error, message: 'hook test', hook_context: { level: :error, event: event }
      )
      subject.push(entry)
      subject.stop

      expect(fired_events.size).to eq(1)
      expect(fired_events.first[:message]).to eq('hook test')
    end
  end

  describe 'LogEntry' do
    subject { described_class.new(logger) }

    it 'is a frozen Data struct' do
      entry = Legion::Logging::AsyncWriter::LogEntry.new(level: :info, message: 'test', hook_context: nil)
      expect(entry).to be_frozen
    end
  end
end
