# frozen_string_literal: true

require 'spec_helper'
require 'stringio'

RSpec.describe Legion::Logging::MethodTracer do
  let(:output) { StringIO.new }
  let(:sample_class) do
    Class.new do
      def greet(name:)
        "Hello, #{name}"
      end
    end
  end

  before do
    Legion::Logging.setup(level: 'debug', color: false, log_file: File::NULL, log_stdout: false)
    Legion::Logging.log.reopen(output)
    Legion::Logging.log_writer = nil
  end

  after do
    described_class.detach_all
    Legion::Logging.stop_async_writer
    Thread.current[:_legion_trace_stack] = nil
  end

  it 'leaves calls untraced when disabled' do
    described_class.attach(sample_class)
    expect(sample_class.new.greet(name: 'disabled')).to eq('Hello, disabled')
    Legion::Logging.stop_async_writer
    expect(output.string).to be_empty
  end

  it 'traces each call and return once and stops tracing after detach' do
    stub_const('Legion::Logging::MethodTracer::ENABLED', true)
    2.times { described_class.attach(sample_class) }
    sample_class.new.greet(name: 'recorded')
    described_class.detach(sample_class)
    sample_class.new.greet(name: 'not recorded')
    Legion::Logging.stop_async_writer

    expect(output.string.lines.size).to eq(2)
    expect(output.string).to include('greet', 'recorded')
    expect(output.string).not_to include('not recorded')
  end

  it 'lets a traced method finish while its configured output is blocked' do
    stub_const('Legion::Logging::MethodTracer::ENABLED', true)
    entered = Queue.new
    release = Queue.new
    first = true
    Legion::Logging.log.formatter = lambda do |_severity, _time, _progname, message|
      if first
        first = false
        entered << Thread.current
        release.pop
      end
      "#{message}\n"
    end
    described_class.attach(sample_class)
    producer = Thread.new { sample_class.new.greet(name: 'async trace') }
    output_thread = entered.pop(timeout: 3)

    expect(output_thread).not_to be_nil
    expect(producer.join(1)).to equal(producer)
    expect(producer.value).to eq('Hello, async trace')
    expect(output_thread).not_to equal(producer)
    release << true
    expect(Legion::Logging.stop_async_writer).to be(true)
    expect(output.string).to include('greet', 'async trace')
  ensure
    release << true
    producer&.join(3)
  end
end
