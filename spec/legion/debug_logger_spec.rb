# frozen_string_literal: true

require 'spec_helper'

require 'legion/logging'

RSpec.describe Legion::Logging do
  it 'can create logger class' do
    @logger = Legion::Logging::Logger.new(level: 'debug', async: false)

    expect(@logger.class).to be_a Class
    expect(@logger.log).to be_a_kind_of Logger
    expect(@logger).to be_a_kind_of Legion::Logging::Logger
  end

  describe 'log level debug' do
    before do
      @logger = Legion::Logging::Logger.new(level: 'debug', async: false)
    end

    it 'can log debug messages' do
      expect { @logger.debug('message') }.to output(/message/).to_stdout_from_any_process
      expect { @logger.debug('message') }.to output(/DEBUG/).to_stdout_from_any_process
      expect { @logger.debug('message') }.to_not output(/INFO/).to_stdout_from_any_process
      expect { @logger.debug('message') }.to_not output(/WARN/).to_stdout_from_any_process
      expect { @logger.debug('message') }.to_not output(/ERROR/).to_stdout_from_any_process
      expect { @logger.debug('message') }.to_not output(/FATAL/).to_stdout_from_any_process
      expect { @logger.unknown('message') }.to output(/ANY/).to_stdout_from_any_process
    end
  end

  describe 'can log with level set to warn' do
    before do
      @logger = Legion::Logging::Logger.new(level: 'debug', async: false)
    end

    it 'will show debug, info, warn, error and fatal messages' do
      expect { @logger.debug('message') }.to output(/message/).to_stdout_from_any_process
      expect { @logger.debug('message') }.to output(/DEBUG/).to_stdout_from_any_process

      expect { @logger.info('message') }.to output(/message/).to_stdout_from_any_process
      expect { @logger.info('message') }.to output(/INFO/).to_stdout_from_any_process

      expect { @logger.warn('message') }.to output(/message/).to_stdout_from_any_process
      expect { @logger.warn('message') }.to output(/WARN/).to_stdout_from_any_process

      expect { @logger.error('message') }.to output(/message/).to_stdout_from_any_process
      expect { @logger.error('message') }.to output(/ERROR/).to_stdout_from_any_process

      expect { @logger.fatal('message') }.to output(/message/).to_stdout_from_any_process
      expect { @logger.fatal('message') }.to output(/FATAL/).to_stdout_from_any_process

      expect { @logger.unknown('message') }.to output(/message/).to_stdout_from_any_process
      expect { @logger.unknown('message') }.to output(/ANY/).to_stdout_from_any_process
    end
  end
end
