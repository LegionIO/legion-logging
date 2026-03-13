# frozen_string_literal: true

require 'spec_helper'

require 'legion/logging'

RSpec.describe Legion::Logging do
  it 'can create logger class' do
    @logger = Legion::Logging::Logger.new(level: 'warn')

    expect(@logger.class).to be_a Class
    expect(@logger.log).to be_a_kind_of Logger
    expect(@logger).to be_a_kind_of Legion::Logging::Logger
  end

  describe 'log level warn with level set to debug' do
    before do
      @logger = Legion::Logging::Logger.new(level: 'warn')
    end

    it 'can log warn messages' do
      expect { @logger.warn('message') }.to output(/message/).to_stdout_from_any_process
      expect { @logger.warn('message') }.to output(/WARN/).to_stdout_from_any_process
      expect { @logger.warn('message') }.to_not output(/DEBUG/).to_stdout_from_any_process
      expect { @logger.warn('message') }.to_not output(/INFO/).to_stdout_from_any_process
      expect { @logger.warn('message') }.to_not output(/ERROR/).to_stdout_from_any_process
      expect { @logger.warn('message') }.to_not output(/FATAL/).to_stdout_from_any_process
      expect { @logger.warn('message') }.to_not output(/ANY/).to_stdout_from_any_process
    end
  end

  describe 'can log with level set to warn' do
    before do
      @logger = Legion::Logging::Logger.new(level: 'debug')
      @logger.log_level('warn')
    end

    it 'will show fatal, error, warn and unknown messages' do
      expect { @logger.warn('message') }.to output(/message/).to_stdout_from_any_process
      expect { @logger.warn('message') }.to output(/WARN/).to_stdout_from_any_process

      expect { @logger.error('message') }.to output(/message/).to_stdout_from_any_process
      expect { @logger.error('message') }.to output(/ERROR/).to_stdout_from_any_process

      expect { @logger.fatal('message') }.to output(/message/).to_stdout_from_any_process
      expect { @logger.fatal('message') }.to output(/FATAL/).to_stdout_from_any_process

      expect { @logger.unknown('message') }.to output(/message/).to_stdout_from_any_process
      expect { @logger.unknown('message') }.to output(/ANY/).to_stdout_from_any_process
    end

    it 'will not show info or debug messages' do
      expect { @logger.debug('message') }.to_not output(/message/).to_stdout_from_any_process
      expect { @logger.debug('message') }.to_not output(/DEBUG/).to_stdout_from_any_process

      expect { @logger.info('message') }.to_not output(/message/).to_stdout_from_any_process
      expect { @logger.info('message') }.to_not output(/INFO/).to_stdout_from_any_process
    end
  end
end
