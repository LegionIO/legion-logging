# frozen_string_literal: true

require 'spec_helper'
require 'legion/logging/shipper/file_transport'
require 'tmpdir'

RSpec.describe Legion::Logging::Shipper::FileTransport do
  describe '.ship' do
    it 'writes a JSON line to the configured file' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'siem.log')
        stub_const('Legion::Settings', Module.new)
        allow(Legion::Settings).to receive(:[]).and_return(nil)
        allow(Legion::Settings).to receive(:dig).with(:logging, :shipper, :file, :path).and_return(path)

        event = { level: 'error', message: 'test event' }
        result = described_class.ship(event)

        expect(result).to be(true)
        expect(File.exist?(path)).to be(true)
        line = File.readlines(path).first
        parsed = JSON.parse(line)
        expect(parsed['level']).to eq('error')
        expect(parsed['message']).to eq('test event')
      end
    end

    it 'creates parent directories if they do not exist' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'nested', 'dirs', 'siem.log')
        stub_const('Legion::Settings', Module.new)
        allow(Legion::Settings).to receive(:[]).and_return(nil)
        allow(Legion::Settings).to receive(:dig).with(:logging, :shipper, :file, :path).and_return(path)

        described_class.ship({ level: 'warn', message: 'hello' })
        expect(File.exist?(path)).to be(true)
      end
    end

    it 'appends multiple events' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'siem.log')
        stub_const('Legion::Settings', Module.new)
        allow(Legion::Settings).to receive(:[]).and_return(nil)
        allow(Legion::Settings).to receive(:dig).with(:logging, :shipper, :file, :path).and_return(path)

        described_class.ship({ level: 'error', message: 'first' })
        described_class.ship({ level: 'error', message: 'second' })

        lines = File.readlines(path)
        expect(lines.size).to eq(2)
      end
    end

    it 'returns false and does not raise on write error' do
      stub_const('Legion::Settings', Module.new)
      allow(Legion::Settings).to receive(:[]).and_return(nil)
      allow(Legion::Settings).to receive(:dig).with(:logging, :shipper, :file, :path)
                                              .and_return('/nonexistent_root_dir/siem.log')
      allow(FileUtils).to receive(:mkdir_p).and_raise(Errno::EACCES, 'permission denied')

      expect(described_class.ship({ level: 'error', message: 'test' })).to be(false)
    end

    it 'falls back to DEFAULT_PATH when Legion::Settings is not defined' do
      hide_const('Legion::Settings') if defined?(Legion::Settings)
      allow(File).to receive(:open).and_return(nil)
      allow(FileUtils).to receive(:mkdir_p)
      io = double('io', puts: nil)
      allow(File).to receive(:open).with(described_class::DEFAULT_PATH, 'a').and_yield(io)
      expect(io).to receive(:puts)
      described_class.ship({ level: 'warn', message: 'fallback' })
    end
  end
end
