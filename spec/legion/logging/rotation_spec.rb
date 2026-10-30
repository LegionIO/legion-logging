# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'tmpdir'
require 'legion/logging/rotation'

RSpec.describe Legion::Logging::Rotation do
  describe '.resolve' do
    it 'accepts string keys and converts megabytes to bytes' do
      opts = described_class.resolve(raw: { 'max_size_mb' => 10, 'max_files' => 2 })
      expect(opts).to include(max_bytes: 10 * 1024 * 1024, max_files: 2)
    end

    it 'disables rotation when passed false' do
      expect(described_class.resolve(raw: false)[:enabled]).to be(false)
    end

    it 'normalizes nonfinite sizes and fractional retention to usable limits' do
      opts = described_class.resolve(raw: { max_size_mb: Float::INFINITY, max_files: 0.5 })
      expect(opts[:max_bytes]).to be_a(Integer).and be_positive
      expect(opts[:max_files]).to be_a(Integer).and be_positive
    end

    it 'normalizes nonfinite retention and sizes that overflow during byte conversion' do
      opts = described_class.resolve(raw: { max_size_mb: Float::MAX, max_files: Float::INFINITY })
      expect(opts[:max_bytes]).to be_a(Integer).and be_positive
      expect(opts[:max_files]).to be_a(Integer).and be_positive
    end

    it 'keeps sub-byte positive sizes usable' do
      expect(described_class.resolve(raw: { max_size_mb: Float::MIN })[:max_bytes]).to eq(1)
    end

    it 'reports malformed limits while falling back to usable values' do
      expect do
        opts = described_class.resolve(raw: { max_size_mb: -1, max_files: 'abc' })
        expect(opts[:max_bytes]).to be_positive
        expect(opts[:max_files]).to be_positive
      end.to output(/invalid numeric limit.*ArgumentError/).to_stderr
    end
  end

  describe '.from_settings' do
    it 'keeps the outer lookup guarded across multiple nested reads' do
      settings = Module.new
      stub_const('Legion::Settings', settings)
      reads = 0
      allow(settings).to receive(:[]) do
        reads += 1
        raise 'recursive settings lookup' if reads > 1

        expect(described_class.from_settings).to be_nil
        expect(described_class.from_settings).to be_nil
        { rotation: { max_files: 2 } }
      end

      expect(described_class.from_settings).to eq(max_files: 2)
      expect(reads).to eq(1)
    end

    it 'guards settings readiness checks that themselves log' do
      settings = Module.new
      stub_const('Legion::Settings', settings)
      checks = 0
      allow(settings).to receive(:loaded?) do
        checks += 1
        raise 'recursive readiness check' if checks > 1

        expect(described_class.from_settings).to be_nil
        true
      end
      allow(settings).to receive(:[]).with(:logging).and_return(rotation: { max_files: 2 })

      expect(described_class.from_settings).to eq(max_files: 2)
    end

    it 'reports failed reads and allows a later lookup to recover' do
      settings = Module.new
      stub_const('Legion::Settings', settings)
      allow(settings).to receive(:[]).and_raise(IOError, 'settings unavailable')
      expect { expect(described_class.from_settings).to be_nil }.to output(/settings unavailable/).to_stderr
      allow(settings).to receive(:[]).and_return(rotation: { max_files: 3 })

      expect(described_class.from_settings).to eq(max_files: 3)
    end
  end

  describe '.shift_files' do
    it 'shifts archives and drops the oldest beyond max_files' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'legion.log')
        File.write(path, 'current')
        File.write("#{path}.1", 'one')
        File.write("#{path}.2", 'two')

        described_class.shift_files(path: path, max_files: 2)

        expect(File.exist?(path)).to be(false)
        expect(File.read("#{path}.1")).to eq('current')
        expect(File.read("#{path}.2")).to eq('one')
        expect(File.exist?("#{path}.3")).to be(false)
      end
    end

    it 'propagates archive deletion failures instead of silently discarding them' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'legion.log')
        File.write(path, 'current')
        File.write("#{path}.1", 'archive')
        allow(File).to receive(:unlink).with("#{path}.1").and_raise(Errno::EACCES)

        expect { described_class.shift_files(path: path, max_files: 1) }.to raise_error(Errno::EACCES)
        expect(File.read(path)).to eq('current')
        expect(File.read("#{path}.1")).to eq('archive')
      ensure
        allow(File).to receive(:unlink).and_call_original
      end
    end
  end

  describe '.regular_file_path' do
    it 'returns the path for an append-mode file IO' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'out.log')
        File.open(path, 'a') do |io|
          expect(File.realpath(described_class.regular_file_path(io: io))).to eq(File.realpath(path))
        end
      end
    end

    it 'returns nil for a file not opened in append mode' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'out.log')
        File.open(path, 'w') { |io| expect(described_class.regular_file_path(io: io)).to be_nil }
      end
    end

    it 'returns nil for a pipe' do
      reader, writer = IO.pipe
      expect(described_class.regular_file_path(io: writer)).to be_nil
    ensure
      reader&.close
      writer&.close
    end
  end
end
