# frozen_string_literal: true

require 'spec_helper'
require 'legion/logging'
require 'legion/logging/multi_io'
require 'tmpdir'

RSpec.describe Legion::Logging::MultiIO do
  let(:tmpdir) { Dir.mktmpdir('legion-logging') }
  let(:log_file) { File.join(tmpdir, 'test.log') }

  after { FileUtils.rm_rf(tmpdir) }

  describe '#write' do
    it 'writes to all targets' do
      file = File.new(log_file, 'a')
      io = described_class.new($stdout, file)

      expect { io.write("hello\n") }.to output("hello\n").to_stdout_from_any_process

      io.close
      expect(File.read(log_file)).to include('hello')
    end
  end

  describe '#close' do
    it 'closes file targets but not stdout' do
      file = File.new(log_file, 'a')
      io = described_class.new($stdout, file)
      io.close

      expect(file.closed?).to be(true)
      expect($stdout.closed?).to be(false)
    end
  end

  describe '#flush' do
    it 'flushes all targets' do
      file = File.new(log_file, 'a')
      io = described_class.new($stdout, file)
      expect { io.flush }.not_to raise_error
      io.close
    end
  end
end

RSpec.describe 'dual output logging' do
  let(:tmpdir) { Dir.mktmpdir('legion-logging') }
  let(:log_file) { File.join(tmpdir, 'test.log') }

  after { FileUtils.rm_rf(tmpdir) }

  it 'writes to both stdout and file via setup' do
    Legion::Logging.setup(level: 'info', log_file: log_file, async: false)

    expect { Legion::Logging.info('dual test') }.to output(/dual test/).to_stdout_from_any_process
    expect(File.read(log_file)).to include('dual test')

    # Reset to stdout-only for other specs
    Legion::Logging.setup(level: 'debug', async: false)
  end

  it 'writes to file only when log_stdout is false' do
    Legion::Logging.setup(level: 'info', log_file: log_file, log_stdout: false, async: false)

    expect { Legion::Logging.info('file only') }.not_to output(/file only/).to_stdout_from_any_process
    expect(File.read(log_file)).to include('file only')

    Legion::Logging.setup(level: 'debug', async: false)
  end

  it 'works with Logger instances' do
    logger = Legion::Logging::Logger.new(level: 'info', log_file: log_file, async: false)

    expect { logger.info('instance dual') }.to output(/instance dual/).to_stdout_from_any_process
    expect(File.read(log_file)).to include('instance dual')
  end

  it 'Logger instance with log_stdout false writes to file only' do
    logger = Legion::Logging::Logger.new(level: 'info', log_file: log_file, log_stdout: false, async: false)

    expect { logger.info('file only instance') }.not_to output(/file only instance/).to_stdout_from_any_process
    expect(File.read(log_file)).to include('file only instance')
  end
end
