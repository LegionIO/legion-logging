# frozen_string_literal: true

require 'spec_helper'
require 'legion/logging/shipper'
require 'tmpdir'

RSpec.describe Legion::Logging::Shipper do
  let(:transport) { Legion::Logging::Shipper::FileTransport }
  let(:directory) { Dir.mktmpdir('legion-shipper') }
  let(:path) { File.join(directory, 'events.jsonl') }
  let(:config) do
    { logging: { shipper: { enabled: true, transport: 'file', levels: ['warn'], batch_size: 2,
                           buffer_size: 4, flush_interval: 60, file: { path: path } } } }
  end

  before do
    stub_const('Legion::Settings', Module.new)
    allow(Legion::Settings).to receive(:dig) { |*keys| config.dig(*keys) }
    allow(Legion::Settings).to receive(:[]) { |key| config[key] || {} }
    Legion::Logging::Redactor.refresh_patterns!
  end

  after do
    allow(transport).to receive(:ship_batch).and_call_original
    described_class.flush(timeout: 3)
    described_class.stop(timeout: 3)
    FileUtils.remove_entry(directory)
  end

  def shipped_events
    File.exist?(path) ? File.readlines(path).map { |line| JSON.parse(line) } : []
  end

  it 'does not deliver when disabled' do
    config[:logging][:shipper][:enabled] = false
    described_class.ship({ level: 'error', message: 'disabled' })
    expect(described_class.flush).to be(true)
    expect(shipped_events).to be_empty
  end

  it 'filters below the minimum and preserves higher severity events' do
    config[:logging][:shipper][:levels] = ['error']
    described_class.ship({ level: 'warn', message: 'below minimum' })
    described_class.ship({ level: 'error', message: 'at minimum' })
    described_class.ship({ level: 'fatal', message: 'above minimum' })
    expect(described_class.flush).to be(true)
    expect(shipped_events.map { |event| event['message'] }).to eq(['at minimum', 'above minimum'])
  end

  it 'redacts accepted events and flushes a partial batch without modifying the input' do
    event = { level: 'error', message: 'SSN 123-45-6789' }
    described_class.ship(event)
    expect(described_class.flush).to be(true)
    expect(shipped_events.first['message']).to include('[REDACTED]')
    expect(event[:message]).to eq('SSN 123-45-6789')
  end

  it 'returns from the threshold-triggering ship while delivery is blocked on the worker' do
    config[:logging][:shipper][:batch_size] = 1
    entered = Queue.new
    release = Queue.new
    allow(transport).to receive(:ship_batch).and_wrap_original do |original, batch|
      entered << Thread.current
      release.pop
      original.call(batch)
    end
    producer = Thread.new { described_class.ship({ level: 'error', message: 'threshold' }) }
    delivery_thread = entered.pop(timeout: 3)

    expect(delivery_thread).not_to be_nil
    expect(producer.join(1)).to equal(producer)
    expect(delivery_thread).not_to equal(producer)
    expect(shipped_events).to be_empty
    release << true
    expect(described_class.flush).to be(true)
    expect(shipped_events.first['message']).to eq('threshold')
  ensure
    release << true
    producer&.join(3)
  end

  it 'counts in-flight events toward bounded backpressure and resumes after delivery' do
    config[:logging][:shipper].merge!(batch_size: 1, buffer_size: 1)
    entered = Queue.new
    release = Queue.new
    allow(transport).to receive(:ship_batch).and_wrap_original do |original, batch|
      entered << true
      release.pop
      original.call(batch)
    end
    described_class.ship({ level: 'error', message: 'in flight' })
    expect(entered.pop(timeout: 3)).to be(true)
    producer = Thread.new { described_class.ship({ level: 'error', message: 'backpressured' }) }
    expect(producer.join(0.05)).to be_nil

    release << true
    expect(producer.join(3)).to equal(producer)
    release << true
    expect(described_class.flush).to be(true)
    expect(shipped_events.map { |event| event['message'] }).to eq(['in flight', 'backpressured'])
  ensure
    2.times { release << true }
    producer&.join(3)
  end

  it 'retains a failed batch and delivers it before newer events on the next flush' do
    attempts = 0
    allow(transport).to receive(:ship_batch).and_wrap_original do |original, batch|
      attempts += 1
      attempts == 1 ? false : original.call(batch)
    end
    described_class.ship({ level: 'error', message: 'retry me' })
    expect(described_class.flush).to be(false)
    described_class.ship({ level: 'error', message: 'newer' })
    expect(described_class.flush).to be(true)
    expect(shipped_events.map { |event| event['message'] }).to eq(['retry me', 'newer'])
  end

  it 'times out a flush without moving blocked delivery onto the caller' do
    config[:logging][:shipper][:batch_size] = 1
    entered = Queue.new
    release = Queue.new
    allow(transport).to receive(:ship_batch).and_wrap_original do |original, batch|
      entered << true
      release.pop
      original.call(batch)
    end
    described_class.ship({ level: 'error', message: 'slow delivery' })
    expect(entered.pop(timeout: 3)).to be(true)
    flusher = Thread.new { described_class.flush(timeout: 0.01) }
    expect(flusher.join(1)).to equal(flusher)
    expect(flusher.value).to be(false)
    release << true
    expect(described_class.flush).to be(true)
    expect(shipped_events.first['message']).to eq('slow delivery')
  ensure
    release << true
    flusher&.join(3)
  end
end
