# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'async output through the standard Logger interface' do
  let(:sink) do
    Class.new do
      attr_reader :entered, :release, :messages

      def initialize
        @entered = Queue.new
        @release = Queue.new
        @messages = []
        @first = true
      end

      def write(message)
        if @first
          @first = false
          @entered << true
          @release.pop
        end
        @messages << message
        message.bytesize
      end

      def close; end
    end.new
  end
  let(:logger) { Legion::Logging::Logger.new(level: 'debug', trace: true, color: false, log_file: File::NULL, log_stdout: false) }

  before do
    Legion::Logging.log_writer = nil
    logger.log.reopen(sink)
  end

  after do
    sink.release << true
    logger.stop_async_writer
  end

  it 'queues raw Logger APIs and instance trace behind blocked output while preserving context' do
    logger.info('hold sink')
    expect(sink.entered.pop(timeout: 3)).to be(true)
    producer = Thread.new do
      Thread.current[:legion_log_request_id] = 'request-22'
      logger.log.info('raw info')
      logger.log.log(Logger::ERROR, 'standard log')
      logger.log << "unformatted output\n"
      logger.trace('instance trace', log_caller: false)
    end

    expect(producer.join(1)).to equal(producer)
    expect(sink.messages).to be_empty
    sink.release << true
    expect(logger.stop_async_writer).to be(true)
    expect(sink.messages.join).to match(/hold sink.*raw info.*standard log.*unformatted output.*instance trace/m)
    expect(sink.messages.grep(/raw info/).first).to include('request_id=request-22')
  ensure
    sink.release << true
    producer&.join(3)
  end

  it 'reports rejected async writes instead of falling back to producer IO' do
    logger.instance_variable_get(:@async_writer).stop

    expect { logger.info('rejected message') }.to raise_error(ClosedQueueError)
    expect { logger.log.info('rejected raw message') }.to raise_error(ClosedQueueError)
    expect(sink.messages).to be_empty
  end
end
