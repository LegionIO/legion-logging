# frozen_string_literal: true

require 'spec_helper'
require 'legion/logging/shipper'

RSpec.describe Legion::Logging::Shipper do
  before do
    described_class.instance_variable_set(:@buffer, nil)
    described_class.instance_variable_set(:@mutex, nil)
    described_class.instance_variable_set(:@flush_thread, nil)
  end

  describe '.enabled?' do
    it 'returns false when Legion::Settings is not defined' do
      hide_const('Legion::Settings') if defined?(Legion::Settings)
      expect(described_class.enabled?).to be(false)
    end

    it 'returns false when settings say disabled' do
      stub_const('Legion::Settings', Module.new)
      allow(Legion::Settings).to receive(:[]).and_return(nil)
      allow(Legion::Settings).to receive(:[]).with(:logging, :shipper, :enabled).and_return(false)
      expect(described_class.enabled?).to be(false)
    end

    it 'returns true when settings say enabled' do
      stub_const('Legion::Settings', Module.new)
      allow(Legion::Settings).to receive(:[]).and_return(nil)
      allow(Legion::Settings).to receive(:[]).with(:logging, :shipper, :enabled).and_return(true)
      expect(described_class.enabled?).to be(true)
    end
  end

  describe '.ship' do
    before do
      stub_const('Legion::Settings', Module.new)
      allow(Legion::Settings).to receive(:[]).and_return(nil)
      allow(Legion::Settings).to receive(:[]).with(:logging, :shipper, :enabled).and_return(true)
      allow(Legion::Settings).to receive(:[]).with(:logging, :shipper, :transport).and_return('file')
      allow(Legion::Settings).to receive(:[]).with(:logging, :shipper, :levels).and_return(%w[warn error fatal])
      allow(Legion::Settings).to receive(:[]).with(:logging, :shipper, :batch_size).and_return(100)
      allow(Legion::Settings).to receive(:[]).with(:logging, :redactor, :custom_patterns).and_return(nil)
    end

    it 'does nothing when disabled' do
      allow(Legion::Settings).to receive(:[]).with(:logging, :shipper, :enabled).and_return(false)
      expect(described_class).not_to receive(:buffer_event)
      described_class.ship({ level: 'error', message: 'test' })
    end

    it 'does nothing when event level is below minimum' do
      file_transport = Legion::Logging::Shipper::FileTransport
      expect(file_transport).not_to receive(:ship)
      described_class.ship({ level: 'debug', message: 'test' })
    end

    it 'buffers events at or above minimum level' do
      described_class.ship({ level: 'warn', message: 'test' })
      expect(described_class.instance_variable_get(:@buffer)).not_to be_empty
    end

    it 'redacts PII before buffering' do
      described_class.ship({ level: 'error', message: 'SSN 123-45-6789' })
      buffer = described_class.instance_variable_get(:@buffer)
      expect(buffer.first[:message]).to include('[REDACTED]')
    end
  end

  describe '.flush' do
    before do
      stub_const('Legion::Settings', Module.new)
      allow(Legion::Settings).to receive(:[]).and_return(nil)
      allow(Legion::Settings).to receive(:[]).with(:logging, :shipper, :transport).and_return('file')
      allow(Legion::Settings).to receive(:[]).with(:logging, :shipper, :batch_size).and_return(100)
    end

    it 'does nothing when buffer is nil' do
      described_class.instance_variable_set(:@buffer, nil)
      expect { described_class.flush }.not_to raise_error
    end

    it 'does nothing when buffer is empty' do
      described_class.instance_variable_set(:@buffer, [])
      described_class.instance_variable_set(:@mutex, Mutex.new)
      expect(Legion::Logging::Shipper::FileTransport).not_to receive(:ship)
      described_class.flush
    end

    it 'calls the transport with buffered events' do
      described_class.instance_variable_set(:@mutex, Mutex.new)
      described_class.instance_variable_set(:@buffer, [{ level: 'error', message: 'test' }])
      allow(Legion::Logging::Shipper::FileTransport).to receive(:ship).and_return(true)
      described_class.flush
      expect(Legion::Logging::Shipper::FileTransport).to have_received(:ship)
    end

    it 'clears the buffer after flushing' do
      described_class.instance_variable_set(:@mutex, Mutex.new)
      described_class.instance_variable_set(:@buffer, [{ level: 'error', message: 'test' }])
      allow(Legion::Logging::Shipper::FileTransport).to receive(:ship).and_return(true)
      described_class.flush
      expect(described_class.instance_variable_get(:@buffer)).to be_empty
    end
  end

  describe 'level filtering' do
    before do
      stub_const('Legion::Settings', Module.new)
      allow(Legion::Settings).to receive(:[]).and_return(nil)
      allow(Legion::Settings).to receive(:[]).with(:logging, :shipper, :enabled).and_return(true)
      allow(Legion::Settings).to receive(:[]).with(:logging, :shipper, :transport).and_return('file')
      allow(Legion::Settings).to receive(:[]).with(:logging, :shipper, :batch_size).and_return(100)
      allow(Legion::Settings).to receive(:[]).with(:logging, :redactor, :custom_patterns).and_return(nil)
    end

    {
      'debug' => %w[debug info warn error fatal],
      'info'  => %w[info warn error fatal],
      'warn'  => %w[warn error fatal],
      'error' => %w[error fatal],
      'fatal' => %w[fatal]
    }.each do |min_level, shippable|
      context "when minimum level is #{min_level}" do
        before do
          allow(Legion::Settings).to receive(:[]).with(:logging, :shipper, :levels).and_return([min_level])
        end

        shippable.each do |level|
          it "ships #{level} events" do
            described_class.ship({ level: level, message: 'test' })
            buffer = described_class.instance_variable_get(:@buffer)
            expect(buffer).not_to be_empty
          end
        end

        (Legion::Logging::Shipper::LEVEL_ORDER - shippable).each do |level|
          it "does not ship #{level} events" do
            described_class.ship({ level: level, message: 'test' })
            buffer = described_class.instance_variable_get(:@buffer)
            expect(buffer.to_a).to be_empty
          end
        end
      end
    end
  end

  describe 'transport selection' do
    before do
      stub_const('Legion::Settings', Module.new)
      allow(Legion::Settings).to receive(:[]).and_return(nil)
      allow(Legion::Settings).to receive(:[]).with(:logging, :shipper, :enabled).and_return(true)
      allow(Legion::Settings).to receive(:[]).with(:logging, :shipper, :levels).and_return(['debug'])
      allow(Legion::Settings).to receive(:[]).with(:logging, :shipper, :batch_size).and_return(1)
      allow(Legion::Settings).to receive(:[]).with(:logging, :redactor, :custom_patterns).and_return(nil)
    end

    it 'uses file transport when configured' do
      allow(Legion::Settings).to receive(:[]).with(:logging, :shipper, :transport).and_return('file')
      allow(Legion::Logging::Shipper::FileTransport).to receive(:ship).and_return(true)
      described_class.instance_variable_set(:@mutex, Mutex.new)
      described_class.instance_variable_set(:@buffer, [])
      described_class.ship({ level: 'debug', message: 'test' })
      expect(Legion::Logging::Shipper::FileTransport).to have_received(:ship)
    end

    it 'uses http transport when configured' do
      allow(Legion::Settings).to receive(:[]).with(:logging, :shipper, :transport).and_return('http')
      allow(Legion::Logging::Shipper::HttpTransport).to receive(:ship).and_return(true)
      described_class.instance_variable_set(:@mutex, Mutex.new)
      described_class.instance_variable_set(:@buffer, [])
      described_class.ship({ level: 'debug', message: 'test' })
      expect(Legion::Logging::Shipper::HttpTransport).to have_received(:ship)
    end
  end
end
