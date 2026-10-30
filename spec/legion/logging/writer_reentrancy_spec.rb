# frozen_string_literal: true

require 'spec_helper'
require 'stringio'

RSpec.describe 'logging from writer callbacks' do
  let(:output) { StringIO.new }

  before do
    Legion::Logging.setup(level: 'debug', format: :json, log_file: File::NULL, log_stdout: false)
    Legion::Logging.log.reopen(output)
    Legion::Logging.start_async_writer(buffer_size: 1)
    Legion::Logging.log_writer = nil
    Legion::Logging.exception_writer = nil
    Legion::Logging.clear_hooks!
  end

  after do
    Legion::Logging.stop_async_writer
    Legion::Logging.log_writer = nil
    Legion::Logging.exception_writer = nil
    Legion::Logging.disable_hooks!
    Legion::Logging.clear_hooks!
  end

  it 'preserves nested writer and hook logs locally without waiting for queue capacity or forwarding recursively' do
    entered = Queue.new
    release = Queue.new
    writer_calls = 0
    hook_calls = 0
    Legion::Logging.log_writer = lambda do |_event, **|
      writer_calls += 1
      entered << true
      release.pop
      Legion::Logging.warn('nested warning')
      Legion::Logging.info('nested info')
    end
    Legion::Logging.on_warn do |_message, _event|
      hook_calls += 1
      Legion::Logging.warn('nested hook warning')
    end
    Legion::Logging.enable_hooks!

    Legion::Logging.warn('outer warning')
    expect(entered.pop(timeout: 3)).to be(true)
    Legion::Logging.info('queued backlog')
    release << true
    expect(Legion::Logging.stop_async_writer).to be(true)

    messages = output.string.lines.map { |line| JSON.parse(line).fetch('message') }
    expect(messages).to include('nested warning', 'nested info', 'nested hook warning', 'queued backlog')
    expect(writer_calls).to eq(1)
    expect(hook_calls).to eq(1)
  ensure
    release&.<< true
  end

  it 'writes nested exception events locally instead of invoking the exception writer recursively' do
    calls = 0
    Legion::Logging.exception_writer = lambda do |_event, **|
      calls += 1
      Legion::Logging.log_exception(RuntimeError.new('nested exception'))
    end

    Legion::Logging.log_exception(RuntimeError.new('outer exception'))
    expect(Legion::Logging.stop_async_writer).to be(true)

    events = output.string.lines.map { |line| JSON.parse(line) }
    expect(calls).to eq(1)
    expect(events).to include(hash_including('exception_class' => 'RuntimeError', 'message' => 'nested exception'))
  end
end
