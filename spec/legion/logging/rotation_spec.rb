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

RSpec.describe Legion::Logging::RotatingFile do
  let(:dir) { Dir.mktmpdir('legion-rotation') }
  let(:path) { File.join(dir, 'legion.log') }

  before do
    allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(0.0, 2.0, 4.0, 6.0)
  end

  after { FileUtils.rm_rf(dir) }

  it 'rotates when the file exceeds max_bytes and keeps max_files archives' do
    file = described_class.new(path: path, max_bytes: 100, max_files: 2)
    4.times { |i| file.write("#{i.to_s * 150}\n") }
    file.close

    expect(File.read(path)).to eq("#{'3' * 150}\n")
    expect(File.read("#{path}.1")).to eq("#{'2' * 150}\n")
    expect(File.read("#{path}.2")).to eq("#{'1' * 150}\n")
    expect(File.exist?("#{path}.3")).to be(false)
  ensure
    file&.close
  end

  it 'reopens when another process rotated the file out from under it' do
    file = described_class.new(path: path, max_bytes: 10_000, max_files: 2)
    file.write("before\n")
    File.rename(path, "#{path}.1")
    file.write("after\n")
    file.close

    expect(File.read(path)).to eq("after\n")
    expect(File.read("#{path}.1")).to eq("before\n")
  ensure
    file&.close
  end

  it 'reports failed rotation and preserves the incoming log message' do
    file = described_class.new(path: path, max_bytes: 1, max_files: 1)
    file.write('before')
    allow(File).to receive(:rename).with(path, "#{path}.1").and_raise(Errno::EACCES)

    expect { file.write('after') }.to output(/RotatingFile.*EACCES/).to_stderr
    expect(File.read(path)).to eq('beforeafter')
  ensure
    file&.close
  end

  it 'leaves non-regular devices intact even when rotation is explicitly requested' do
    File.symlink(File::NULL, path)
    file = described_class.new(path: path, max_bytes: 1, max_files: 1)
    expect(file.rotate!).to be(false)
    expect(file.write('discarded')).to eq(9)
    expect(File.stat(path).chardev?).to be(true)
  ensure
    file&.close
  end

  it 'works as a ::Logger device' do
    file = described_class.new(path: path, max_bytes: 10_000, max_files: 2)
    logger = Logger.new(file)
    logger.info('hello rotation')
    logger.close
    expect(File.read(path)).to include('hello rotation')
  ensure
    file&.close
  end
end

RSpec.describe Legion::Logging::StdioRotator do
  let(:dir) { Dir.mktmpdir('legion-stdio-rotation') }
  let(:path) { File.join(dir, 'legion.log') }

  before do
    allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(0.0, 2.0, 4.0, 6.0)
  end

  after { FileUtils.rm_rf(dir) }

  it 'rotates redirected stdout and keeps duplicated stderr pointing at the new file' do
    out = File.new(path, 'a')
    err = out.dup
    rotator = described_class.new(max_bytes: 50, max_files: 3, stdout: out, stderr: err)

    rotator.write('x' * 80)
    rotator.write("new\n")
    err.write("raw stderr\n")
    err.flush

    expect(File.read("#{path}.1")).to eq('x' * 80)
    expect(File.read(path)).to eq("new\nraw stderr\n")
  ensure
    out&.close
    err&.close
  end

  it 'rotates stderr independently while stdout is below its limit' do
    err_path = File.join(dir, 'error.log')
    out = File.new(path, 'a')
    err = File.new(err_path, 'a')
    rotator = described_class.new(max_bytes: 50, max_files: 2, stdout: out, stderr: err)
    err.write('e' * 80)

    rotator.write('out')
    rotator.flush
    err.write('new error')
    err.flush

    expect(File.read(path)).to eq('out')
    expect(File.exist?("#{path}.1")).to be(false)
    expect(File.read("#{err_path}.1")).to eq('e' * 80)
    expect(File.read(err_path)).to eq('new error')
  ensure
    out&.close
    err&.close
  end

  it 'rotates eligible stderr even when stdout is a pipe' do
    reader, writer = IO.pipe
    err = File.new(path, 'a')
    rotator = described_class.new(max_bytes: 1, max_files: 1, stdout: writer, stderr: err)
    err.write('error')

    rotator.write('out')
    rotator.flush
    err.write('new')
    err.flush

    expect(reader.read(3)).to eq('out')
    expect(File.read("#{path}.1")).to eq('error')
    expect(File.read(path)).to eq('new')
  ensure
    reader&.close
    writer&.close
    err&.close
  end

  it 'reopens shared streams at their original path after an external rename' do
    out = File.new(path, 'a')
    err = out.dup
    rotator = described_class.new(max_bytes: 50, max_files: 2, stdout: out, stderr: err)
    rotator.write('before')
    rotator.flush
    File.rename(path, "#{path}.external")
    File.write(path, 'replacement ')

    rotator.write('after ')
    err.write('error')
    err.flush

    expect(File.read("#{path}.external")).to eq('before')
    expect(File.read(path)).to eq('replacement after error')
    expect(File.exist?("#{path}.external.1")).to be(false)
  ensure
    out&.close
    err&.close
  end

  it 'recognizes a shared inode through different hardlink paths without rotating twice' do
    alias_path = File.join(dir, 'alias.log')
    out = File.new(path, 'a')
    File.link(path, alias_path)
    err = File.new(alias_path, 'a')
    rotator = described_class.new(max_bytes: 1, max_files: 2, stdout: out, stderr: err)
    rotator.write('before')
    rotator.write('after ')
    err.write('error')
    err.flush

    expect(File.read(path)).to eq('after error')
    expect(File.read("#{path}.1")).to eq('before')
    expect(File.read(alias_path)).to eq('before')
    expect(File.exist?("#{alias_path}.1")).to be(false)
  ensure
    out&.close
    err&.close
  end

  it 'handles stdout and stderr referring to the same IO object' do
    out = File.new(path, 'a')
    rotator = described_class.new(max_bytes: 1, max_files: 1, stdout: out, stderr: out)
    rotator.write('before')
    rotator.write('after')

    expect(File.read("#{path}.1")).to eq('before')
    expect(File.read(path)).to eq('after')
  ensure
    out&.close
  end

  it 'does nothing when neither stream is a regular append-mode file' do
    reader, writer = IO.pipe
    rotator = described_class.new(max_bytes: 1, max_files: 1, stdout: writer, stderr: writer)
    expect(rotator.rotate!).to be(false)
  ensure
    reader&.close
    writer&.close
  end

  it 'never closes the underlying stdout' do
    out = File.new(path, 'a')
    described_class.new(max_bytes: 50, max_files: 1, stdout: out, stderr: out).close
    out.write('still open')
    out.flush
    expect(File.read(path)).to eq('still open')
  ensure
    out&.close
  end
end
