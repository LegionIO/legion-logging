# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'tmpdir'
require 'legion/logging/rotation'

RSpec.describe Legion::Logging::StdioRotator do
  let(:dir) { Dir.mktmpdir('legion-stdio-cap') }
  let(:path) { File.join(dir, 'output.log') }
  let(:handles) { [] }
  let(:rotators) { [] }

  after do
    rotators.reverse_each { |rotator| rotator.shutdown unless rotator.closed? }
    handles.reverse_each { |handle| handle.close unless handle.closed? }
    FileUtils.rm_rf(dir)
  end

  def open_stream(path:, mode: 'ab')
    File.new(path, mode).tap { |file| handles << file }
  end

  def make_pipe
    IO.pipe.tap { |pipe| handles.concat(pipe) }
  end

  def capture(stdout:, stderr:, max_bytes: 8, max_files: 2)
    described_class.new(stdout: stdout, stderr: stderr, max_bytes: max_bytes, max_files: max_files).tap { |rotator| rotators << rotator }
  end

  def write_raw_bytes(stream:, bytes:)
    offset = 0
    offset += stream.syswrite(bytes.byteslice(offset, 16_384)) while offset < bytes.bytesize
    offset
  end

  def retained_bytes(path:, max_files: 2)
    paths = max_files.downto(1).map { |index| "#{path}.#{index}" } << path
    paths.filter_map { |file| File.binread(file) if File.exist?(file) }.join
  end

  def expect_cap(path:, max_bytes: 8, max_files: 2)
    paths = (1..max_files).map { |index| "#{path}.#{index}" } << path
    expect(paths.filter_map { |file| File.size(file) if File.exist?(file) }).to all(be <= max_bytes)
    expect(File.exist?("#{path}.#{max_files + 1}")).to be(false)
  end

  def block_first_sink_write(entered:, release:)
    allow(Legion::Logging::RotatingFile).to receive(:new).and_wrap_original do |original, **arguments|
      sink = original.call(**arguments)
      first = true
      allow(sink).to receive(:write).and_wrap_original do |write, *messages|
        if first
          first = false
          entered << true
          raise IOError, 'test drain was not released' unless release.pop(timeout: 5)
        end
        write.call(*messages)
      end
      sink
    end
  end

  it 'captures raw descriptor writes and preserves their order across a shared stdout and stderr' do
    out = open_stream(path: path)
    err = out.dup.tap { |file| handles << file }
    rotator = capture(stdout: out, stderr: err)
    raw = IO.new(out.fileno, autoclose: false)

    raw.syswrite('01234567')
    err.syswrite('abcdefgh')
    raw.syswrite('ABCDEFGH')

    expect(rotator.flush(timeout: nil)).to equal(rotator)
    expect(retained_bytes(path: path)).to eq('01234567abcdefghABCDEFGH')
    expect_cap(path: path)
    expect(rotator.shutdown(timeout: nil)).to be(true)
  end

  it 'captures a shared IO object once and does not detach it on ordinary close' do
    out = open_stream(path: path)
    rotator = capture(stdout: out, stderr: out)
    rotator.close
    out.write('still open')

    expect(rotator.flush).to equal(rotator)
    expect(retained_bytes(path: path)).to eq('still open')
    expect(out).not_to be_closed
    expect(out.stat).to be_pipe
  end

  it 'uses one archive sequence for different paths to the same inode' do
    alias_path = File.join(dir, 'alias.log')
    out = open_stream(path: path)
    File.link(path, alias_path)
    err = open_stream(path: alias_path)
    rotator = capture(stdout: out, stderr: err)
    out.syswrite('01234567')
    err.syswrite('abcdefgh')
    out.syswrite('ABCDEFGH')

    expect(rotator.flush).to equal(rotator)
    expect(retained_bytes(path: path)).to eq('01234567abcdefghABCDEFGH')
    expect(File.exist?("#{alias_path}.1")).to be(false)
    expect_cap(path: path)
  end

  it 'bounds separate stdout and stderr files without needing a wrapper write' do
    error_path = File.join(dir, 'error.log')
    out = open_stream(path: path)
    err = open_stream(path: error_path)
    rotator = capture(stdout: out, stderr: err)
    out.syswrite('01234567abcdefghABCDEFGH')
    err.syswrite('00000000111111112222222233333333')

    expect(rotator.flush).to equal(rotator)
    expect(retained_bytes(path: path)).to eq('01234567abcdefghABCDEFGH')
    expect(retained_bytes(path: error_path)).to eq('111111112222222233333333')
    expect_cap(path: path)
    expect_cap(path: error_path)
  end

  it 'captures stderr while preserving an unrelated piped stdout' do
    reader, writer = make_pipe
    err = open_stream(path: path)
    original_inode = writer.stat.ino
    rotator = capture(stdout: writer, stderr: err)
    err.syswrite('01234567abcdefghABCDEFGH')
    rotator.write('untouched pipe')

    expect(rotator.flush).to equal(rotator)
    expect(reader.read(14)).to eq('untouched pipe')
    expect(writer.stat.ino).to eq(original_inode)
    expect(retained_bytes(path: path)).to eq('01234567abcdefghABCDEFGH')
    expect_cap(path: path)
  end

  it 'leaves nonappend files unrotated' do
    out = open_stream(path: path, mode: 'wb')
    rotator = capture(stdout: out, stderr: out)
    rotator.write('not an append file')

    expect(rotator.flush).to equal(rotator)
    expect(rotator.rotate!).to be(false)
    expect(File.binread(path)).to eq('not an append file')
    expect(out.stat).to be_file
    expect(File.exist?("#{path}.1")).to be(false)
  end

  it 'splits an oversized raw payload into bounded files without losing its retained suffix' do
    out = open_stream(path: path)
    rotator = capture(stdout: out, stderr: out, max_bytes: 4096)
    payload = (0...256).map(&:chr).join.b * 8192
    expect(write_raw_bytes(stream: out, bytes: payload)).to eq(payload.bytesize)

    expect(rotator.flush).to equal(rotator)
    expect(retained_bytes(path: path)).to eq(payload.byteslice(-12_288, 12_288))
    expect_cap(path: path, max_bytes: 4096)
  end

  it 'follows an external replacement at the originally discovered path' do
    out = open_stream(path: path)
    rotator = capture(stdout: out, stderr: out, max_bytes: 32)
    out.syswrite('before')
    expect(rotator.flush).to equal(rotator)
    File.rename(path, "#{path}.external")
    File.binwrite(path, 'replacement ')
    out.syswrite('after')

    expect(rotator.flush).to equal(rotator)
    expect(File.binread("#{path}.external")).to eq('before')
    expect(File.binread(path)).to eq('replacement after')
  end

  it 'does not report a flush while a consumed chunk is still blocked in the file sink' do
    entered = Queue.new
    release = Queue.new
    block_first_sink_write(entered: entered, release: release)
    out = open_stream(path: path)
    rotator = capture(stdout: out, stderr: out)
    out.syswrite('pending')
    expect(entered.pop(timeout: 2)).to be(true)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect(rotator.flush(timeout: 0.02)).to be(false)
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1
    expect(File.binread(path)).to eq('')
    release << true

    expect(rotator.flush).to equal(rotator)
    expect(retained_bytes(path: path)).to eq('pending')
  ensure
    release&.<<(true)
  end

  it 'backpressures a raw producer rather than buffering its payload in an unbounded queue' do
    entered = Queue.new
    release = Queue.new
    block_first_sink_write(entered: entered, release: release)
    out = open_stream(path: path)
    rotator = capture(stdout: out, stderr: out, max_bytes: 4096)
    payload = 'x' * (2 * 1024 * 1024)
    producer = Thread.new { write_raw_bytes(stream: out, bytes: payload) }
    expect(entered.pop(timeout: 2)).to be(true)

    expect(producer.join(0.02)).to be_nil
    expect(rotator.flush(timeout: 0.02)).to be(false)
    expect_cap(path: path, max_bytes: 4096)
    release << true

    expect(producer.join(5)).to equal(producer)
    expect(producer.value).to eq(payload.bytesize)
    expect(rotator.flush).to equal(rotator)
    expect(retained_bytes(path: path)).to eq('x' * 12_288)
    expect_cap(path: path, max_bytes: 4096)
  ensure
    release&.<<(true)
    producer&.join(5)
  end

  it 'retains its descriptors after a shutdown timeout and can subsequently disable cleanly' do
    entered = Queue.new
    release = Queue.new
    block_first_sink_write(entered: entered, release: release)
    out = open_stream(path: path)
    out.sync = false
    rotator = capture(stdout: out, stderr: out)
    out.syswrite('pending')
    expect(entered.pop(timeout: 2)).to be(true)

    expect(rotator.shutdown(timeout: 0.02)).to be(false)
    expect(out.stat).to be_pipe
    expect(rotator).not_to be_closed
    release << true

    expect(rotator.shutdown).to be(true)
    expect(out.stat).to be_file
    expect(out.sync).to be(false)
    expect(rotator).to be_closed
    out.write(' restored')
    out.flush
    expect(retained_bytes(path: path)).to eq('pending restored')
  ensure
    release&.<<(true)
  end

  it 'keeps capture active when preparing the restoration file blocks past the shutdown deadline' do
    entered = Queue.new
    release = Queue.new
    out = open_stream(path: path)
    rotator = capture(stdout: out, stderr: out)
    first = true
    allow(File).to receive(:new).and_call_original
    allow(File).to receive(:new).with(path, 'ab').and_wrap_original do |open, *arguments|
      if first
        first = false
        entered << true
        raise IOError, 'test restoration was not released' unless release.pop(timeout: 5)
      end
      open.call(*arguments)
    end
    shutdown = Thread.new { rotator.shutdown(timeout: 0.05) }
    expect(entered.pop(timeout: 2)).to be(true)
    expect(shutdown.join(2)).to equal(shutdown)
    expect(shutdown.value).to be(false)
    expect(out.stat).to be_pipe
    release << true
    out.syswrite('retained')

    expect(rotator.flush).to equal(rotator)
    expect(rotator.shutdown).to be(true)
    expect(File.binread(path)).to eq('retained')
  ensure
    release&.<<(true)
    shutdown&.join(5)
  end

  it 'waits for synchronous reconfiguration rather than applying it after a reported timeout' do
    entered = Queue.new
    release = Queue.new
    block_first_sink_write(entered: entered, release: release)
    out = open_stream(path: path)
    rotator = capture(stdout: out, stderr: out, max_bytes: 16)
    out.syswrite('0123456789abcdef')
    expect(entered.pop(timeout: 2)).to be(true)
    configuration = Thread.new { rotator.configure(max_bytes: 4, max_files: 1) }

    expect(configuration.join(0.02)).to be_nil
    expect(rotator.shutdown(timeout: 0.02)).to be(false)
    release << true
    expect(configuration.join(2)).to equal(configuration)
    expect(configuration.value).to equal(rotator)
    out.syswrite('ABCDEFGH')

    expect(rotator.flush).to equal(rotator)
    expect(retained_bytes(path: path, max_files: 1)).to eq('ABCDEFGH')
    expect_cap(path: path, max_bytes: 4, max_files: 1)
  ensure
    release&.<<(true)
    configuration&.join(5)
  end

  it 'surfaces drain errors, wakes blocked producers, and never falls back to uncapped writes' do
    entered = Queue.new
    release = Queue.new
    allow(Legion::Logging::RotatingFile).to receive(:new).and_wrap_original do |original, **arguments|
      sink = original.call(**arguments)
      allow(sink).to receive(:write) do
        entered << true
        raise IOError, 'test drain was not released' unless release.pop(timeout: 5)

        raise Errno::ENOSPC, 'full sink'
      end
      sink
    end
    out = open_stream(path: path)
    rotator = capture(stdout: out, stderr: out)
    producer = Thread.new do
      write_raw_bytes(stream: out, bytes: 'x' * (2 * 1024 * 1024))
    rescue SystemCallError => e
      warn("Raw producer received its sink failure: #{e.class}: #{e.message}")
      e
    end
    expect(entered.pop(timeout: 2)).to be(true)
    expect(producer.join(0.02)).to be_nil
    release << true

    expect(producer.join(2)).to equal(producer)
    expect(producer.value).to be_a(Errno::EPIPE)
    expect { rotator.flush }.to raise_error(Errno::ENOSPC)
    expect { rotator.write('uncapped fallback') }.to raise_error(Errno::ENOSPC)
    expect { rotator.shutdown }.to raise_error(Errno::ENOSPC)
    expect(File.binread(path)).to eq('')
    expect(out.stat).to be_pipe
    rotators.delete(rotator)
  ensure
    release&.<<(true)
    producer&.join(5)
  end

  it 'fails closed if the final shutdown drain fails after descriptors were restored' do
    allow(Legion::Logging::RotatingFile).to receive(:new).and_wrap_original do |original, **arguments|
      sink = original.call(**arguments)
      flushes = 0
      allow(sink).to receive(:flush).and_wrap_original do |flush|
        flushes += 1
        raise Errno::ENOSPC, 'final drain failed' if flushes == 2

        flush.call
      end
      sink
    end
    out = open_stream(path: path)
    rotator = capture(stdout: out, stderr: out)
    out.syswrite('pending')

    expect { rotator.shutdown }.to raise_error(Errno::ENOSPC)
    expect(out.stat).to be_pipe
    expect { out.syswrite('uncapped') }.to raise_error(Errno::EPIPE)
    expect(File.binread(path)).to eq('pending')
    rotators.delete(rotator)
  end

  it 'propagates owned-handle cleanup failures without restoring an uncapped writer' do
    allow(Legion::Logging::RotatingFile).to receive(:new).and_wrap_original do |original, **arguments|
      sink = original.call(**arguments)
      allow(sink).to receive(:close).and_wrap_original do |close|
        close.call
        raise IOError, 'sink close failed'
      end
      sink
    end
    out = open_stream(path: path)
    rotator = capture(stdout: out, stderr: out)
    out.syswrite('pending')

    expect { rotator.shutdown }.to raise_error(IOError, 'sink close failed')
    expect(out.stat).to be_pipe
    expect { out.syswrite('uncapped') }.to raise_error(Errno::EPIPE)
    expect(File.binread(path)).to eq('pending')
    rotators.delete(rotator)
  end

  it 'closes restored descriptors if fail-closed reattachment itself fails' do
    allow(Legion::Logging::RotatingFile).to receive(:new).and_wrap_original do |original, **arguments|
      sink = original.call(**arguments)
      allow(sink).to receive(:close).and_wrap_original do |close|
        close.call
        raise IOError, 'sink close failed'
      end
      sink
    end
    out = open_stream(path: path)
    rotator = capture(stdout: out, stderr: out)
    out.syswrite('pending')
    allow(IO).to receive(:pipe).and_raise(Errno::EMFILE)

    expect { rotator.shutdown }.to raise_error(Errno::EMFILE)
    expect(out).to be_closed
    expect(File.binread(path)).to eq('pending')
    rotators.delete(rotator)
  end

  it 'returns false and remains fail-closed if final owned-handle cleanup misses the deadline' do
    entered = Queue.new
    release = Queue.new
    completed = Queue.new
    allow(Legion::Logging::RotatingFile).to receive(:new).and_wrap_original do |original, **arguments|
      sink = original.call(**arguments)
      allow(sink).to receive(:close).and_wrap_original do |close|
        entered << true
        raise IOError, 'test cleanup was not released' unless release.pop(timeout: 5)

        close.call
        completed << true
      end
      sink
    end
    out = open_stream(path: path)
    rotator = capture(stdout: out, stderr: out)
    shutdown = Thread.new { rotator.shutdown(timeout: 0.05) }
    expect(entered.pop(timeout: 2)).to be(true)

    expect(shutdown.join(2)).to equal(shutdown)
    expect(shutdown.value).to be(false)
    expect(out.stat).to be_pipe
    expect { rotator.write('uncapped') }.to raise_error(IOError)
    release << true
    expect(completed.pop(timeout: 2)).to be(true)
    rotators.delete(rotator)
  ensure
    release&.<<(true)
    shutdown&.join(5)
  end

  it 'does not restore or wait for a parent capture from an inherited process' do
    out = open_stream(path: path)
    rotator = capture(stdout: out, stderr: out)
    parent_pid = Process.pid
    allow(Process).to receive(:pid).and_return(parent_pid + 1)

    expect(rotator.shutdown).to be(false)
    expect(rotator.flush).to be(false)
    expect { rotator.configure(max_bytes: 4, max_files: 1) }.to raise_error(IOError)
    expect(out.stat).to be_pipe
    out.syswrite('inherited')
    allow(Process).to receive(:pid).and_return(parent_pid)

    expect(rotator.flush).to equal(rotator)
    expect(retained_bytes(path: path)).to eq('inherited')
  ensure
    allow(Process).to receive(:pid).and_return(parent_pid) if parent_pid
  end

  it 'rolls back already reopened descriptors if construction fails partway through attachment' do
    error_path = File.join(dir, 'error.log')
    out = open_stream(path: path)
    err = open_stream(path: error_path)
    attempts = 0
    allow(err).to receive(:reopen).and_wrap_original do |original, *arguments|
      attempts += 1
      raise IOError, 'attachment failed' if attempts == 1

      original.call(*arguments)
    end

    expect { capture(stdout: out, stderr: err) }.to raise_error(IOError, 'attachment failed')
    out.write('original stdout')
    err.write('original stderr')
    out.flush
    err.flush
    expect(File.binread(path)).to eq('original stdout')
    expect(File.binread(error_path)).to eq('original stderr')
    expect(out.stat).to be_file
    expect(err.stat).to be_file
  end

  describe 'the process-wide factory' do
    after { described_class.reset! }

    it 'reuses an active capture after the original descriptors have become pipes' do
      out = open_stream(path: path)
      allow(described_class).to receive(:new).and_wrap_original do |original, **arguments|
        original.call(**arguments, stdout: out, stderr: out)
      end
      first = described_class.shared(max_bytes: 8, max_files: 2)
      second = described_class.shared(max_bytes: 4, max_files: 1)
      out.syswrite('0123456789ab')

      expect(second).to equal(first)
      expect(second.flush).to equal(second)
      expect(retained_bytes(path: path, max_files: 1)).to eq('456789ab')
      expect_cap(path: path, max_bytes: 4, max_files: 1)
      expect(described_class.reset!).to be(true)
      expect(described_class.current).to be_nil
      expect(out.stat).to be_file
    end

    it 'keeps existing instance loggers usable across capture disable and re-enable' do
      out = open_stream(path: path)
      allow(described_class).to receive(:new).and_wrap_original do |original, **arguments|
        original.call(**arguments, stdout: out, stderr: out)
      end
      logger = Legion::Logging::Logger.new(async: false, color: false, rotation: { max_size_mb: 0.001, max_files: 2 })
      logger.log.formatter = proc { |_severity, _time, _program, message| "#{message}\n" }
      logger.info('before')
      expect(described_class.reset!).to be(true)

      logger.info('disabled')
      expect(logger.stop_async_writer).to be(true)
      expect(File.binread(path)).to eq("before\ndisabled\n")

      described_class.shared(max_bytes: 1048, max_files: 2)
      logger.info('enabled again')
      expect(logger.stop_async_writer).to be(true)
      expect(File.binread(path)).to eq("before\ndisabled\nenabled again\n")
    ensure
      logger&.stop_async_writer
      logger&.log&.close
    end

    it 'only reuses an inherited capture when the requested retention policy matches' do
      out = open_stream(path: path)
      allow(described_class).to receive(:new).and_wrap_original do |original, **arguments|
        original.call(**arguments, stdout: out, stderr: out)
      end
      shared = described_class.shared(max_bytes: 8, max_files: 2)
      parent_pid = Process.pid
      allow(Process).to receive(:pid).and_return(parent_pid + 1)

      expect(described_class.shared(max_bytes: 8, max_files: 2)).to equal(shared)
      expect { described_class.shared(max_bytes: 4, max_files: 2) }.to raise_error(IOError)
      expect { described_class.shared(max_bytes: 8, max_files: 1) }.to raise_error(IOError)
      out.syswrite('inherited')
      allow(Process).to receive(:pid).and_return(parent_pid)

      expect(shared.flush).to equal(shared)
      expect(retained_bytes(path: path)).to eq('inherited')
    ensure
      allow(Process).to receive(:pid).and_return(parent_pid) if parent_pid
    end

    it 'retains the shared capture when reset reaches its deadline' do
      entered = Queue.new
      release = Queue.new
      block_first_sink_write(entered: entered, release: release)
      out = open_stream(path: path)
      allow(described_class).to receive(:new).and_wrap_original do |original, **arguments|
        original.call(**arguments, stdout: out, stderr: out)
      end
      shared = described_class.shared(max_bytes: 8, max_files: 2)
      out.syswrite('pending')
      expect(entered.pop(timeout: 2)).to be(true)

      expect(described_class.reset!(timeout: 0.02)).to be(false)
      expect(described_class.current).to equal(shared)
      expect(out.stat).to be_pipe
      release << true

      expect(described_class.reset!).to be(true)
      expect(described_class.current).to be_nil
      expect(File.binread(path)).to eq('pending')
    ensure
      release&.<<(true)
    end

    it 'returns nil without redirecting ineligible streams' do
      reader, writer = make_pipe
      allow(described_class).to receive(:new).and_wrap_original do |original, **arguments|
        original.call(**arguments, stdout: writer, stderr: writer)
      end

      expect(described_class.shared(max_bytes: 8, max_files: 2)).to be_nil
      writer.syswrite('original pipe')
      expect(reader.read(13)).to eq('original pipe')
      expect(described_class.current).to be_nil
    end
  end
end
