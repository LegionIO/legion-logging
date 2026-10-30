# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'tmpdir'
require 'legion/logging/rotation'

RSpec.describe Legion::Logging::RotatingFile do
  let(:dir) { Dir.mktmpdir('legion-bounded-rotation') }
  let(:path) { File.join(dir, 'legion.log') }
  let(:devices) { [] }

  after do
    devices.each(&:close)
    FileUtils.rm_rf(dir)
  end

  def build_file(max_bytes:, max_files:)
    described_class.new(path: path, max_bytes: max_bytes, max_files: max_files).tap { |file| devices << file }
  end

  def archive_paths
    Dir.glob("#{path}.[0-9]*").sort_by { |archive| archive.delete_prefix("#{path}.").to_i }
  end

  def retained_bytes
    (archive_paths.reverse + [path]).map { |file| File.binread(file) }.join
  end

  def expect_bound(max_bytes:, max_files:)
    sizes = (archive_paths + [path]).map { |file| File.size(file) }
    expect(archive_paths.size).to be <= max_files
    expect(sizes).to all(be <= max_bytes)
    expect(sizes.sum).to be <= max_bytes * (max_files + 1)
  end

  it 'bounds each write, preserves exact-full files, and counts multiple arguments in bytes' do
    file = build_file(max_bytes: 4, max_files: 2)

    expect(file.write('ab', 'cd')).to eq(4)
    expect(file.write('')).to eq(0)
    expect(archive_paths).to be_empty
    expect(File.binread(path)).to eq('abcd')
    expect_bound(max_bytes: 4, max_files: 2)

    expect(file.write('ef', 'ghij')).to eq(6)
    expect(File.binread(path)).to eq('ij')
    expect(File.binread("#{path}.1")).to eq('efgh')
    expect(File.binread("#{path}.2")).to eq('abcd')
    expect_bound(max_bytes: 4, max_files: 2)

    expect(file.write('klmnop')).to eq(6)
    expect(file.flush).to equal(file)
    expect(retained_bytes).to eq('efghijklmnop')
    expect_bound(max_bytes: 4, max_files: 2)
  end

  it 'retains the newest bytes of a record larger than the whole retention window' do
    file = build_file(max_bytes: 70_001, max_files: 2)
    payload = ('é🙂' * 50_000).b

    expect(file.write(payload)).to eq(300_000)
    expect(File.binread(path)).to eq(payload.byteslice(280_004, 19_996))
    expect(File.binread("#{path}.1")).to eq(payload.byteslice(210_003, 70_001))
    expect(File.binread("#{path}.2")).to eq(payload.byteslice(140_002, 70_001))
    expect_bound(max_bytes: 70_001, max_files: 2)
  end

  it 'normalizes oversized existing files in place and removes excess archives before accepting writes' do
    active = ('older active bytes' * 15_000).b
    archived = ('older archived bytes' * 15_000).b
    File.binwrite(path, active)
    File.binwrite("#{path}.1", archived)
    File.binwrite("#{path}.2", 'short archive')
    File.binwrite("#{path}.7", 'expired archive')
    reader = File.new(path, 'rb')
    archive_reader = File.new("#{path}.1", 'rb')

    build_file(max_bytes: 70_001, max_files: 2)

    expect(reader.read).to eq(active.byteslice(-70_001, 70_001))
    expect(archive_reader.read).to eq(archived.byteslice(-70_001, 70_001))
    expect(File.binread("#{path}.2")).to eq('short archive')
    expect(File.exist?("#{path}.7")).to be(false)
    expect_bound(max_bytes: 70_001, max_files: 2)
  ensure
    reader&.close
    archive_reader&.close
  end

  it 'applies tighter byte and archive limits immediately while retaining each file tail' do
    File.binwrite(path, 'active-0123456789')
    File.binwrite("#{path}.1", 'archive-abcdefghij')
    File.binwrite("#{path}.2", 'older')
    File.binwrite("#{path}.3", 'oldest')
    file = build_file(max_bytes: 32, max_files: 3)

    expect(file.configure(max_bytes: 7, max_files: 1)).to equal(file)
    expect(File.binread(path)).to eq('3456789')
    expect(File.binread("#{path}.1")).to eq('defghij')
    expect_bound(max_bytes: 7, max_files: 1)

    file.write('X')
    expect(retained_bytes).to eq('3456789X')
    expect_bound(max_bytes: 7, max_files: 1)
  end

  it 'rejects unusable limits without changing the active retention policy' do
    file = build_file(max_bytes: 4, max_files: 1)
    file.write('full')

    expect { file.configure(max_bytes: 0, max_files: 1) }.to raise_error(ArgumentError)
    expect { build_file(max_bytes: 4, max_files: 0) }.to raise_error(ArgumentError)

    file.write('next')
    expect(retained_bytes).to eq('fullnext')
    expect_bound(max_bytes: 4, max_files: 1)
  end

  it 'refuses an over-limit write when rotation fails instead of writing to the full file' do
    file = build_file(max_bytes: 4, max_files: 1)
    file.write('full')
    allow(File).to receive(:rename).and_call_original
    allow(File).to receive(:rename).with(path, "#{path}.1").and_raise(Errno::EACCES)

    expect { file.write('next') }.to raise_error(Errno::EACCES)
    expect(File.binread(path)).to eq('full')
    expect_bound(max_bytes: 4, max_files: 1)

    allow(File).to receive(:rename).with(path, "#{path}.1").and_call_original
    expect(file.write('next')).to eq(4)
    expect(retained_bytes).to eq('fullnext')
    expect_bound(max_bytes: 4, max_files: 1)
  end

  it 'does not accept new bytes after a failed retention-policy change' do
    File.binwrite(path, 'active')
    File.binwrite("#{path}.2", 'expired')
    file = build_file(max_bytes: 10, max_files: 2)
    allow(File).to receive(:unlink).and_call_original
    allow(File).to receive(:unlink).with("#{path}.2").and_raise(Errno::EACCES)

    expect { file.configure(max_bytes: 4, max_files: 1) }.to raise_error(Errno::EACCES)
    expect { file.write('new') }.to raise_error(Errno::EACCES)
    expect(File.binread(path)).to eq('tive')

    allow(File).to receive(:unlink).with("#{path}.2").and_call_original
    file.write('new')
    expect(retained_bytes).to eq('tivenew')
    expect_bound(max_bytes: 4, max_files: 1)
  ensure
    allow(File).to receive(:unlink).and_call_original
  end

  it 'reopens an externally renamed active path before the very next write' do
    file = build_file(max_bytes: 20, max_files: 2)
    file.write("before\n")
    File.rename(path, "#{path}.1")

    file.write("after\n")

    expect(File.binread(path)).to eq("after\n")
    expect(File.binread("#{path}.1")).to eq("before\n")
    expect(file.size).to eq(6)
  end

  it 'normalizes an oversized external replacement before appending' do
    file = build_file(max_bytes: 4, max_files: 1)
    file.write('old')
    File.rename(path, "#{path}.external")
    File.binwrite(path, 'replacement')

    file.write('!')

    expect(File.binread("#{path}.external")).to eq('old')
    expect(retained_bytes).to eq('ment!')
    expect_bound(max_bytes: 4, max_files: 1)
  end

  it 'does not pin deleted log bytes through an idle same-path device' do
    skip 'descriptor filesystem is unavailable' unless File.directory?('/dev/fd')

    idle = build_file(max_bytes: 4, max_files: 1)
    idle.write('old!')
    retired = File.stat(path)
    writer = build_file(max_bytes: 4, max_files: 1)
    writer.write('new!nextlast')

    descriptors = Dir.glob('/dev/fd/[0-9]*').filter_map do |descriptor|
      File.stat(descriptor)
    rescue Errno::ENOENT, Errno::EBADF => e
      warn("Descriptor disappeared during retention scan: #{e.class}: #{e.message}")
      nil
    end
    pinned = descriptors.select do |stat|
      stat.file? && stat.nlink.zero? && stat.dev == retired.dev && stat.ino == retired.ino
    end

    expect(pinned).to be_empty
    expect(retained_bytes).to eq('nextlast')
    expect_bound(max_bytes: 4, max_files: 1)
  end

  it 'serializes independent same-path devices without losing or interleaving multi-argument writes' do
    first = build_file(max_bytes: 13, max_files: 40)
    second = build_file(max_bytes: 13, max_files: 40)
    gate = Queue.new
    writers = [[first, 'left'], [second, 'right']].map do |file, prefix|
      Thread.new do
        gate.pop
        30.times { |index| file.write(prefix, '-', index.to_s.rjust(2, '0'), "\n") }
      end
    end
    2.times { gate << true }
    writers.each(&:value)
    expected = %w[left right].flat_map { |prefix| 30.times.map { |index| "#{prefix}-#{index.to_s.rjust(2, '0')}\n" } }

    expect(retained_bytes.lines.sort).to eq(expected.sort)
    expect_bound(max_bytes: 13, max_files: 40)
  end

  it 'coordinates a file device inherited by a forked process' do
    skip 'fork is unavailable on this Ruby platform' unless Process.respond_to?(:fork)

    file = build_file(max_bytes: 11, max_files: 32)
    reader, writer = IO.pipe
    pid = Process.fork do
      writer.close
      reader.read(1)
      reader.close
      20.times { |index| file.write("child-#{index.to_s.rjust(2, '0')}\n") }
      file.close
      Process.exit!(0)
    end
    reader.close
    writer.write('.')
    writer.close
    20.times { |index| file.write("owner-#{index.to_s.rjust(2, '0')}\n") }
    _child, status = Process.wait2(pid)
    expected = %w[child owner].flat_map { |prefix| 20.times.map { |index| "#{prefix}-#{index.to_s.rjust(2, '0')}\n" } }

    expect(status.success?).to be(true)
    expect(retained_bytes.lines.sort).to eq(expected.sort)
    expect_bound(max_bytes: 11, max_files: 32)
  ensure
    reader&.close unless reader&.closed?
    writer&.close unless writer&.closed?
    Process.wait(pid) if pid && !status
  end

  it 'leaves nonregular devices intact during writes, reconfiguration, and explicit rotation' do
    File.symlink(File::NULL, path)
    file = build_file(max_bytes: 1, max_files: 1)

    expect(file.rotate!).to be(false)
    expect(file.write('discarded', ' bytes')).to eq(15)
    file.configure(max_bytes: 2, max_files: 2)
    expect(file.rotate!).to be(false)
    expect(File.stat(path).chardev?).to be(true)
    expect(archive_paths).to be_empty
    expect(File.exist?("#{path}.lock")).to be(false)
  end

  it 'works as a Logger device and rejects writes after closing' do
    file = build_file(max_bytes: 10_000, max_files: 2)
    logger = Logger.new(file)
    logger.info('hello bounded rotation')
    logger.close

    expect(File.binread(path)).to include('hello bounded rotation')
    expect(file).to be_closed
    expect { file.write('too late') }.to raise_error(IOError)
  ensure
    logger&.close
  end
end
