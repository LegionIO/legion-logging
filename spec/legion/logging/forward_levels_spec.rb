# frozen_string_literal: true

require 'spec_helper'
require 'stringio'

RSpec.describe 'configured log forwarding' do
  let(:output) { StringIO.new }
  let(:events) { [] }
  let(:config) { { logging: { transport: {} } } }

  before do
    stub_const('Legion::Settings', Module.new)
    allow(Legion::Settings).to receive(:[]) { |key| config[key] || {} }
    allow(Legion::Settings).to receive(:dig) { |*keys| config.dig(*keys) }
    Legion::Logging.setup(level: 'debug', color: false, log_file: File::NULL, log_stdout: false)
    Legion::Logging.log.reopen(output)
    Legion::Logging.clear_hooks!
    Legion::Logging.log_writer = ->(event, **) { events << event }
  end

  after do
    Legion::Logging.stop_async_writer
    Legion::Logging.log_writer = nil
  end

  it 'forwards default warning and error levels without suppressing local lower-severity output' do
    %i[debug info warn error fatal unknown].each { |level| Legion::Logging.public_send(level, "local #{level}") }
    expect(Legion::Logging.stop_async_writer).to be(true)

    expect(events.map { |event| event[:level] }).to eq(%i[warn error fatal])
    expect(output.string).to include('local debug', 'local info', 'local warn', 'local error', 'local fatal', 'local unknown')
  end

  it 'uses configured string levels for both synchronous and asynchronous forwarding' do
    config[:logging][:transport][:log_levels] = %w[debug info]
    [false, true].each do |async|
      Legion::Logging.setup(level: 'debug', color: false, log_file: File::NULL, log_stdout: false, async: async)
      events.clear
      %i[debug info warn error fatal unknown].each { |level| Legion::Logging.public_send(level, "configured #{level}") }
      expect(Legion::Logging.stop_async_writer).to be(true)
      expect(events.map { |event| event[:level] }).to eq(%i[debug info])
    end
  end

  it 'retains the default forwarding policy when the configured list is empty' do
    config[:logging][:transport][:log_levels] = []
    Legion::Logging.info('local only')
    Legion::Logging.warn('default forwarded')
    expect(Legion::Logging.stop_async_writer).to be(true)

    expect(events.map { |event| event[:message] }).to eq(['default forwarded'])
    expect(output.string).to include('local only', 'default forwarded')
  end
end
