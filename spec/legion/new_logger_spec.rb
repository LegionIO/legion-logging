# frozen_string_literal: true

require 'spec_helper'

require 'legion/logging'

RSpec.describe Legion::Logging do
  before { Legion::Logging.setup(level: 'debug', async: false) }

  it 'can create logger class' do
    @logger = Legion::Logging::Logger.new(level: 'debug', async: false)

    expect(@logger.class).to be_a Class
    expect(@logger.log).to be_a_kind_of Logger
    expect(@logger).to be_a_kind_of Legion::Logging::Logger
  end

  describe 'log level debug' do
    before do
      @logger = Legion::Logging::Logger.new(level: 'info', async: false)
    end

    it 'can log info messages' do
      expect { @logger.info('message') }.to output(/message/).to_stdout_from_any_process
      expect { @logger.info('message') }.to output(/INFO/).to_stdout_from_any_process
    end
  end

  describe 'it can trace' do
    before do
      @logger = Legion::Logging::Logger.new(level: 'debug', trace: true, async: false)
    end

    it 'can log trace' do
      expect { @logger.trace('message') }.to output(/message/).to_stdout_from_any_process
      expect { @logger.trace('message', log_caller: true) }.to output(/message/).to_stdout_from_any_process
      expect { @logger.trace('message', log_caller: false) }.to output(/message/).to_stdout_from_any_process
      expect { @logger.trace('message', size: 0) }.to output(/message/).to_stdout_from_any_process
      expect { @logger.trace('message', size: nil) }.to output(/message/).to_stdout_from_any_process
    end

    it '.runner_exception' do
      expect do
        Legion::Logging.runner_exception(StandardError.new('test'), test: 'test')
      end.to output(/ERROR/).to_stdout_from_any_process
    end

    it '.thread' do
      expect(Legion::Logging.thread(kvl: true)).to be_a String
      expect(Legion::Logging.thread(kvl: false)).to be_a String
    end

    it 'can use generic logger self' do
      expect { Legion::Logging.info('message') }.to output(/message/).to_stdout_from_any_process
      expect { Legion::Logging.info('message') }.to output(/INFO/).to_stdout_from_any_process
    end
  end
end
