# frozen_string_literal: true

require 'spec_helper'
require 'legion/logging/async_writer'
require 'tmpdir'
require 'stringio'

RSpec.describe Legion::Logging::AsyncWriter do
  let(:logger) { Logger.new($stdout) }
  let(:entry_context) do
    { force: false, writer_context: nil, segments: nil, method_ctx: nil, caller_trace: nil,
      conv_id: nil, request_id: nil, exchange_id: nil, chain_id: nil }
  end

  after { subject.stop if subject.alive? }

  describe '#start / #stop lifecycle' do
    subject { described_class.new(logger) }

    let(:output) { StringIO.new }
    let(:logger) { Logger.new(output) }
    let(:entered) { Queue.new }
    let(:release) { Queue.new }
    let(:entry) do
      described_class::LogEntry.new(**entry_context, level: :info, message: 'accepted before start')
    end

    before do
      logger.formatter = lambda do |_severity, _time, _progname, message|
        entered << Thread.current
        release.pop
        "#{message}\n"
      end
    end

    after do
      release << true
      subject.stop(timeout: 1)
    end

    it 'starts queued work without doing output on the startup caller' do
      subject.push(entry)
      starter = Thread.new { subject.start }
      expect(starter.join(1)).to equal(starter)
      output_thread = entered.pop(timeout: 3)
      expect(output_thread).not_to be_nil
      expect(output_thread).not_to equal(starter)
      release << true
      expect(subject.stop(timeout: 1)).to be(true)
      expect(output.string.lines).to eq(["accepted before start\n"])
    ensure
      release << true
      starter&.join(3)
    end

    it 'bounds shutdown even when accepted work has no running worker' do
      subject.push(entry)
      stopper = Thread.new { subject.stop(timeout: 0.01) }
      output_thread = entered.pop(timeout: 3)
      expect(output_thread).not_to be_nil
      expect(stopper.join(0.5)).to equal(stopper)
      expect(stopper.value).to be(false)
      expect(output_thread).not_to equal(stopper)
      expect(subject.start).to be(false)
      release << true
      expect(subject.stop(timeout: 1)).to be(true)
      expect(output.string.lines).to eq(["accepted before start\n"])
    ensure
      release << true
      stopper&.join(3)
    end

    it 'requests shutdown from its own callback without joining itself' do
      stopped = Queue.new
      subject.start
      subject.push(described_class::EventEntry.new(
                     callback: ->(_event, **) { stopped << subject.stop(timeout: 1) },
                     event: {}, options: {}
                   ))

      expect(stopped.pop(timeout: 3)).to be(false)
      expect(subject.stop(timeout: 1)).to be(true)
      expect(subject.push(entry)).to be(false)
    end
  end

  describe '#push' do
    subject { described_class.new(logger) }

    before { subject.start }

    it 'writes entries to the logger' do
      entry = Legion::Logging::AsyncWriter::LogEntry.new(**entry_context, level: :info, message: 'async test')
      subject.push(entry)
      subject.stop
    end

    it 'writes multiple entries in order' do
      messages = []
      allow(logger).to receive(:info) { |msg| messages << msg }

      3.times do |i|
        subject.push(Legion::Logging::AsyncWriter::LogEntry.new(**entry_context, level: :info, message: "msg-#{i}"))
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

      entry = Legion::Logging::AsyncWriter::LogEntry.new(**entry_context, level: :info, message: 'slow message')

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
        subject.push(Legion::Logging::AsyncWriter::LogEntry.new(**entry_context, level: :info, message: "fill-#{i}"))
      end

      blocked = true
      pusher = Thread.new do
        subject.push(Legion::Logging::AsyncWriter::LogEntry.new(**entry_context, level: :info, message: 'overflow'))
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
        subject.push(Legion::Logging::AsyncWriter::LogEntry.new(**entry_context, level: :warn, message: "drain-#{i}"))
      end
      subject.stop

      expect(messages).to eq((0..4).map { |i| "drain-#{i}" })
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
