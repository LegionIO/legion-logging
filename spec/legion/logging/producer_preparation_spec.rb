# frozen_string_literal: true

require 'spec_helper'
require 'stringio'

RSpec.describe 'asynchronous log preparation' do
  let(:output) { StringIO.new }
  let(:events) { [] }
  let(:helper) { Class.new { include Legion::Logging::Helper }.new }

  before do
    Legion::Logging.setup(level: 'debug', color: false, log_file: File::NULL, log_stdout: false)
    Legion::Logging.log.reopen(output)
    Legion::Logging.log_writer = ->(event, **) { events << event }
    Legion::Logging.exception_writer = ->(event, **) { events << event }
  end

  after do
    Legion::Logging.stop_async_writer
    Legion::Logging.log_writer = nil
    Legion::Logging.exception_writer = nil
  end

  it 'prepares events off the producer while retaining its message, request ID, thread, and call site' do
    entered = Queue.new
    release = Queue.new
    allow(Legion::Logging::EventBuilder).to receive(:build).and_wrap_original do |original, **keywords|
      entered << Thread.current
      release.pop
      original.call(**keywords)
    end
    source_line = nil
    producer = Thread.new do
      message = +'original payload'
      request_id = +'original-request'
      source_line = __LINE__ + 1
      Legion::Logging.warn(message, request_id: request_id)
      message.replace('mutated payload')
      request_id.replace('mutated-request')
    end
    preparation_thread = entered.pop(timeout: 3)

    expect(preparation_thread).not_to be_nil
    expect(producer.join(1)).to equal(producer)
    expect(preparation_thread).not_to equal(producer)
    release << true
    expect(Legion::Logging.stop_async_writer).to be(true)
    expect(events.first).to include(message: 'original payload', thread: producer.object_id)
    expect(events.first[:caller]).to include(file: File.expand_path(__FILE__), line: source_line)
    expect(output.string).to include('original payload', 'original-request')
    expect(output.string).not_to include('mutated')
  ensure
    release << true
    producer&.join(3)
  end

  %i[module helper].each do |entry_point|
    it "prepares #{entry_point} exceptions off the producer without losing task or session context" do
      entered = Queue.new
      release = Queue.new
      Legion::Logging.log_writer = nil
      stub_const('Legion::Context', Module.new do
        def self.current_session
          Thread.current[:legion_session_context]
        end
      end)
      allow(Legion::Logging::EventBuilder).to receive(:build_exception).and_wrap_original do |original, **keywords|
        entered << Thread.current
        release.pop
        original.call(**keywords)
      end
      exception = RuntimeError.new('deferred exception')
      exception.set_backtrace(['/app/jobs/work.rb:42:in `perform`'])
      producer = Thread.new do
        Thread.current[:legion_context] = { task_id: 'task-original', conversation_id: 'conversation-original' }
        Thread.current[:legion_session_context] = Struct.new(:session_id).new('conversation-original')
        if entry_point == :module
          Legion::Logging.log_exception(exception, task_id: 'task-original')
        else
          helper.handle_exception(exception)
        end
        Thread.current[:legion_context][:task_id] = 'changed'
        Thread.current[:legion_session_context] = nil
        exception.set_backtrace(['/changed.rb:1'])
      end
      preparation_thread = entered.pop(timeout: 3)

      expect(preparation_thread).not_to be_nil
      expect(producer.join(1)).to equal(producer)
      expect(preparation_thread).not_to equal(producer)
      release << true
      expect(Legion::Logging.stop_async_writer).to be(true)
      expect(events.first).to include(thread: producer.object_id, task_id: 'task-original',
                                      conversation_id: 'conversation-original', caller_file: '/app/jobs/work.rb', caller_line: 42)
      expect(output.string).to include('deferred exception', '/app/jobs/work.rb:42')
      expect(output.string).not_to include('/changed.rb')
    ensure
      release << true
      producer&.join(3)
    end
  end

  it 'does not initialize unloaded Settings during setup, normal logs, or either exception API' do
    stub_const('Legion::Settings', Module.new do
      def self.loaded?
        @loaded == true
      end

      def self.[](_key)
        @loaded = true
        {}
      end

      def self.dig(*)
        @loaded = true
        nil
      end
    end)
    Legion::Logging.setup(level: 'debug', color: false, log_file: File::NULL, log_stdout: false)
    output = StringIO.new
    Legion::Logging.log.reopen(output)
    Legion::Logging.info('early info')
    Legion::Logging.warn('early warning')
    Legion::Logging.log_exception(RuntimeError.new('early module exception'))
    helper.handle_exception(RuntimeError.new('early helper exception'))
    expect(Legion::Logging.stop_async_writer).to be(true)

    expect(Legion::Settings.loaded?).to be(false)
    expect(output.string).to include('early info', 'early warning', 'early module exception', 'early helper exception')
  end

  it 'preserves a component debug override when the global async logger filters debug' do
    component = Class.new do
      include Legion::Logging::Helper

      def settings
        { log_level: :debug }
      end
    end.new
    Legion::Logging.setup(level: 'error', color: false, log_file: File::NULL, log_stdout: false)
    output = StringIO.new
    Legion::Logging.log.reopen(output)
    Legion::Logging.debug('filtered global debug')
    component.log.debug('visible component debug')
    expect(Legion::Logging.stop_async_writer).to be(true)

    expect(output.string).to include('DEBUG', 'visible component debug')
    expect(output.string).not_to include('filtered global debug')
  end
end
