# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'legion/logging/rotation'

RSpec.describe Legion::Logging::Rotation do
  describe '.resolve' do
    it 'returns defaults of 100 MB x 5 files when nothing is configured' do
      opts = described_class.resolve(nil)
      expect(opts).to include(enabled: true, max_size_mb: 100, max_files: 5, stdio: true)
      expect(opts[:max_bytes]).to eq(100 * 1024 * 1024)
    end

    it 'accepts string keys and overrides individual values' do
      opts = described_class.resolve('max_size_mb' => 10, 'max_files' => 2)
      expect(opts).to include(max_size_mb: 10, max_files: 2, enabled: true)
      expect(opts[:max_bytes]).to eq(10 * 1024 * 1024)
    end

    it 'disables rotation when passed false' do
      expect(described_class.resolve(false)[:enabled]).to be(false)
    end

    it 'falls back to defaults for invalid sizes' do
      opts = described_class.resolve(max_size_mb: -1, max_files: 'abc')
      expect(opts).to include(max_size_mb: 100, max_files: 5)
    end
  end

  describe '.shift_files' do
    it 'shifts archives and drops the oldest beyond max_files' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'legion.log')
        File.write(path, 'current')
        File.write("#{path}.1", 'one')
        File.write("#{path}.2", 'two')

        described_class.shift_files(path, 2)

        expect(File.exist?(path)).to be(false)
        expect(File.read("#{path}.1")).to eq('current')
        expect(File.read("#{path}.2")).to eq('one')
        expect(File.exist?("#{path}.3")).to be(false)
      end
    end
  end

  describe '.regular_file_path' do
    it 'returns the path for an append-mode file IO' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'out.log')
        File.open(path, 'a') do |io|
          expect(File.realpath(described_class.regular_file_path(io))).to eq(File.realpath(path))
        end
      end
    end

    it 'returns nil for a file not opened in append mode' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'out.log')
        File.open(path, 'w') { |io| expect(described_class.regular_file_path(io)).to be_nil }
      end
    end

    it 'returns nil for a pipe' do
      reader, writer = IO.pipe
      expect(described_class.regular_file_path(writer)).to be_nil
    ensure
      reader&.close
      writer&.close
    end
  end
end

RSpec.describe Legion::Logging::RotatingFile do
  let(:dir) { Dir.mktmpdir('legion-rotation') }
  let(:path) { File.join(dir, 'legion.log') }

  after { FileUtils.rm_rf(dir) }

  def force_check(file)
    file.instance_variable_set(:@next_check, 0.0)
  end

  it 'rotates when the file exceeds max_bytes and keeps max_files archives' do
    file = described_class.new(path, max_bytes: 100, max_files: 2)
    4.times do |i|
      force_check(file)
      file.write("#{i.to_s * 150}\n")
    end
    file.close

    expect(File.size(path)).to be < 200
    expect(File.exist?("#{path}.1")).to be(true)
    expect(File.exist?("#{path}.2")).to be(true)
    expect(File.exist?("#{path}.3")).to be(false)
    expect(File.read(path)).to start_with('3')
    expect(File.read("#{path}.1")).to start_with('2')
  end

  it 'reopens when another process rotated the file out from under it' do
    file = described_class.new(path, max_bytes: 10_000, max_files: 2)
    file.write("before\n")
    File.rename(path, "#{path}.1")
    force_check(file)
    file.write("after\n")
    file.close

    expect(File.read(path)).to eq("after\n")
    expect(File.read("#{path}.1")).to eq("before\n")
  end

  it 'works as a ::Logger device' do
    file = described_class.new(path, max_bytes: 10_000, max_files: 2)
    logger = Logger.new(file)
    logger.info('hello rotation')
    logger.close
    expect(File.read(path)).to include('hello rotation')
  end
end

RSpec.describe Legion::Logging::StdioRotator do
  let(:dir) { Dir.mktmpdir('legion-stdio-rotation') }
  let(:path) { File.join(dir, 'legion.log') }

  after { FileUtils.rm_rf(dir) }

  it 'rotates a supervisor-redirected stdout file and keeps stderr pointing at the new file' do
    out = File.new(path, 'a')
    err = out.dup
    rotator = described_class.new(max_bytes: 50, max_files: 3, stdout: out, stderr: err)

    rotator.write('x' * 80)
    rotator.instance_variable_set(:@next_check, 0.0)
    rotator.write("new\n")
    err.write("raw stderr\n")
    err.flush

    expect(File.read("#{path}.1")).to eq('x' * 80)
    expect(File.read(path)).to eq("new\nraw stderr\n")
  ensure
    out&.close
    err&.close
  end

  it 'does nothing when stdout is not a regular append-mode file' do
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
    expect(out.closed?).to be(false)
  ensure
    out&.close
  end
end

RSpec.describe 'Legion::Logging.setup with rotation' do
  let(:dir) { Dir.mktmpdir('legion-setup-rotation') }
  let(:path) { File.join(dir, 'legion.log') }

  after do
    Legion::Logging.setup(level: 'info', async: false)
    FileUtils.rm_rf(dir)
  end

  it 'uses a RotatingFile for log_file by default' do
    Legion::Logging.setup(level: 'info', log_file: path, log_stdout: false, async: false)
    expect(Legion::Logging.log.instance_variable_get(:@logdev).dev).to be_a(Legion::Logging::RotatingFile)
  end

  it 'honours rotation settings passed to setup' do
    Legion::Logging.setup(level: 'info', log_file: path, log_stdout: false, async: false,
                          rotation: { max_size_mb: 1, max_files: 7 })
    dev = Legion::Logging.log.instance_variable_get(:@logdev).dev
    expect(dev.max_bytes).to eq(1024 * 1024)
    expect(dev.max_files).to eq(7)
  end

  it 'uses a plain File when rotation is disabled' do
    Legion::Logging.setup(level: 'info', log_file: path, log_stdout: false, async: false, rotation: { enabled: false })
    expect(Legion::Logging.log.instance_variable_get(:@logdev).dev).to be_a(File)
  end

  it 'reads rotation settings from Legion::Settings when not passed explicitly' do
    stub_const('Legion::Settings', Module.new do
      def self.[](_key)
        { rotation: { max_size_mb: 2, max_files: 3 } }
      end
    end)
    Legion::Logging.setup(level: 'info', log_file: path, log_stdout: false, async: false)
    dev = Legion::Logging.log.instance_variable_get(:@logdev).dev
    expect(dev.max_bytes).to eq(2 * 1024 * 1024)
    expect(dev.max_files).to eq(3)
  end

  it 'wraps stdout in the shared StdioRotator when stdout is an append-mode file' do
    allow(Legion::Logging::Rotation).to receive(:regular_file_path).and_call_original
    allow(Legion::Logging::Rotation).to receive(:regular_file_path).with($stdout).and_return(path)
    Legion::Logging.setup(level: 'info', async: false)
    expect(Legion::Logging.log.instance_variable_get(:@logdev).dev).to be_a(Legion::Logging::StdioRotator)
  ensure
    Legion::Logging::StdioRotator.reset!
  end

  it 'records rotation in current_settings' do
    Legion::Logging.setup(level: 'info', log_file: path, log_stdout: false, async: false, rotation: { max_files: 2 })
    expect(Legion::Logging.current_settings[:rotation]).to eq({ max_files: 2 })
  end
end
