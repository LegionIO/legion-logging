# frozen_string_literal: true

require 'spec_helper'
require 'legion/logging/async_writer'
require 'tmpdir'

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

    it 'times out instead of deadlocking when shutdown cannot finish promptly' do
      gate = Queue.new
      slow_writer_class = Class.new(described_class) do
        def initialize(logger, gate:, **)
          @gate = gate
          super(logger, **)
        end

        private

        def consume
          @gate.pop
          super
        end
      end

      writer = slow_writer_class.new(logger, gate: gate, buffer_size: 1)
      writer.start
      writer.push(Legion::Logging::AsyncWriter::LogEntry.new(
                    level: :info, message: 'blocked', writer_context: nil, segments: nil, method_ctx: nil,
                    caller_trace: nil, conv_id: nil, request_id: nil
                  ))

      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect(writer.stop(timeout: 0.01)).to be(false)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
      expect(elapsed).to be < 0.2

      gate << true
      expect(writer.stop(timeout: 1)).to be(true)
    end
  end

  describe '#push' do
    subject { described_class.new(logger) }

    before { subject.start }

    it 'writes entries to the logger' do
      entry = Legion::Logging::AsyncWriter::LogEntry.new(
        level: :info, message: 'async test', writer_context: nil, segments: nil, method_ctx: nil, caller_trace: nil, conv_id: nil, request_id: nil
      )
      subject.push(entry)
      subject.stop
    end

    it 'writes multiple entries in order' do
      messages = []
      allow(logger).to receive(:info) { |msg| messages << msg }

      3.times do |i|
        subject.push(Legion::Logging::AsyncWriter::LogEntry.new(
                       level: :info, message: "msg-#{i}", writer_context: nil, segments: nil, method_ctx: nil,
                       caller_trace: nil, conv_id: nil, request_id: nil
                     ))
      end
      subject.stop

      expect(messages).to eq(%w[msg-0 msg-1 msg-2])
    end

    it 'waits for an in-flight entry to finish on stop' do
      write_started = Queue.new
      messages = []
      allow(logger).to receive(:info) do |msg|
        write_started << true
        sleep 0.05
        messages << msg
      end

      entry = Legion::Logging::AsyncWriter::LogEntry.new(
        level: :info, message: 'slow message', writer_context: nil, segments: nil, method_ctx: nil, caller_trace: nil, conv_id: nil, request_id: nil
      )

      subject.push(entry)
      write_started.pop
      subject.stop

      expect(messages).to eq(['slow message'])
    end
  end

  describe 'back-pressure' do
    subject { described_class.new(logger, buffer_size: 2) }

    it 'blocks the caller when the queue is full' do
      2.times do |i|
        subject.push(Legion::Logging::AsyncWriter::LogEntry.new(
                       level: :info, message: "fill-#{i}", writer_context: nil, segments: nil, method_ctx: nil,
                       caller_trace: nil, conv_id: nil, request_id: nil
                     ))
      end

      blocked = true
      pusher = Thread.new do
        subject.push(Legion::Logging::AsyncWriter::LogEntry.new(
                       level: :info, message: 'overflow', writer_context: nil, segments: nil, method_ctx: nil,
                       caller_trace: nil, conv_id: nil, request_id: nil
                     ))
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
      5.times do |i|
        subject.push(Legion::Logging::AsyncWriter::LogEntry.new(
                       level: :warn, message: "drain-#{i}", writer_context: nil, segments: nil, method_ctx: nil,
                       caller_trace: nil, conv_id: nil, request_id: nil
                     ))
      end
      subject.stop

      expect(messages).to eq((0..4).map { |i| "drain-#{i}" })
    end
  end

  describe 'writer context' do
    subject { described_class.new(logger) }

    before { subject.start }

    it 'calls log_writer when writer_context is present' do
      captured = nil
      Legion::Logging.log_writer = lambda { |event, routing_key:, headers: nil, properties: nil|
        captured = { event: event, routing_key: routing_key, headers: headers, properties: properties }
      }

      event = { level: :error, message: 'writer test', lex: 'core' }
      entry = Legion::Logging::AsyncWriter::LogEntry.new(
        level: :error, message: 'writer test',
        writer_context: { level: :error, event: event },
        segments: nil, method_ctx: nil, caller_trace: nil, conv_id: nil, request_id: nil
      )
      subject.push(entry)
      deadline = Time.now + 2
      sleep 0.01 while captured.nil? && Time.now < deadline
      expect(captured).not_to be_nil
      expect(captured[:event][:message]).to eq('writer test')

      Legion::Logging.log_writer = nil
    end
  end

  describe 'LogEntry' do
    subject { described_class.new(logger) }

    it 'is a frozen Data struct' do
      entry = Legion::Logging::AsyncWriter::LogEntry.new(
        level: :info, message: 'test', writer_context: nil, segments: nil, method_ctx: nil, caller_trace: nil, conv_id: nil, request_id: nil
      )
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

  it 'defaults to async when async not specified' do
    logger = Legion::Logging::Logger.new(level: 'info')
    expect(logger.async?).to be true
  end
end

RSpec.describe 'async routing through Methods' do
  def emit_info_from_spec(message)
    Legion::Logging.info(message)
  end

  before do
    Legion::Logging.setup(level: 'debug', async: true)
  end

  after do
    Legion::Logging.stop_async_writer
    Legion::Logging.instance_variable_set(:@async_writer, nil)
    Legion::Logging.instance_variable_set(:@async, false)
  end

  it 'routes info through the async writer' do
    writer = Legion::Logging.instance_variable_get(:@async_writer)
    expect(writer).to receive(:push).once
    Legion::Logging.info('async info')
  end

  it 'captures caller metadata on the producer thread before queueing' do
    writer = Legion::Logging.instance_variable_get(:@async_writer)
    expect(writer).to receive(:push) do |entry|
      expect(entry.caller_trace).to include(file: 'async_writer_spec')
    end

    emit_info_from_spec('async caller trace')
  end

  it 'routes warn through the async writer with writer context' do
    writer = Legion::Logging.instance_variable_get(:@async_writer)
    expect(writer).to receive(:push).once
    Legion::Logging.warn('async warn')
  end

  it 'routes fatal through async writer' do
    writer = Legion::Logging.instance_variable_get(:@async_writer)
    expect(writer).to receive(:push).and_call_original
    Legion::Logging.fatal('async fatal')
  end

  it 'falls back to sync when async is disabled' do
    Legion::Logging.stop_async_writer
    expect(Legion::Logging.log).to receive(:debug).with(anything)
    Legion::Logging.debug('sync fallback')
  end

  it 'falls back to sync when the async writer rejects a queued entry' do
    writer = instance_double(
      Legion::Logging::AsyncWriter,
      alive?: true,
      push:   false,
      stop:   true,
      logger: Legion::Logging.log
    )
    Legion::Logging.instance_variable_set(:@async_writer, writer)
    Legion::Logging.instance_variable_set(:@async, true)

    expect(Legion::Logging.log).to receive(:info).with('sync fallback after reject')
    Legion::Logging.info('sync fallback after reject')
  end
end

RSpec.describe 'extended caller metadata under async logging' do
  let(:tmpdir) { Dir.mktmpdir('legion-logging-extended') }
  let(:sync_path) { File.join(tmpdir, 'sync.log') }
  let(:async_path) { File.join(tmpdir, 'async.log') }

  def emit_extended_probe(logger)
    logger.info('extended metadata probe')
  end

  def extract_trace(path)
    match = File.read(path).match(/\[(?<type>[^:\]]+):(?<file>[^:\]]+):(?<function>[^:\]]+):(?<line>\d+)\]/)
    match&.named_captures
  end

  after do
    FileUtils.rm_rf(tmpdir)
  end

  it 'preserves the same extended caller trace in sync and async modes' do
    sync_logger = Legion::Logging::Logger.new(
      level: 'info', lex: 'eval', log_file: sync_path, log_stdout: false, async: false, extended: true
    )
    async_logger = Legion::Logging::Logger.new(
      level: 'info', lex: 'eval', log_file: async_path, log_stdout: false, async: true, extended: true
    )

    emit_extended_probe(sync_logger)
    emit_extended_probe(async_logger)
    async_logger.stop_async_writer

    sync_trace = extract_trace(sync_path)
    async_trace = extract_trace(async_path)

    expect(async_trace).to include('file' => 'async_writer_spec')
    expect(async_trace.except('line')).to eq(sync_trace.except('line'))
  end
end
