# frozen_string_literal: true

require 'spec_helper'

require 'legion/logging'

RSpec.describe Legion::Logging do
  before { Legion::Logging.setup(level: 'debug', async: false) }

  before do
    @logger = Legion::Logging::Logger.new(level: 'debug')
  end
  it 'has a version number' do
    expect(Legion::Logging::VERSION).not_to be nil
  end

  it 'can create logger class' do
    # Legion::Logging.start_logger
    # expect(Legion::Logging.logger.class).to be_a Class
  end

  it 'can log debug' do
    expect { Legion::Logging.debug('message') }.to output(/message/).to_stdout_from_any_process
    expect { Legion::Logging.debug('message') }.to output(/DEBUG/).to_stdout_from_any_process

    expect { Legion::Logging.debug('message') }.to_not output(/INFO/).to_stdout_from_any_process
    expect { Legion::Logging.debug('message') }.to_not output(/WARN/).to_stdout_from_any_process
    expect { Legion::Logging.debug('message') }.to_not output(/ERROR/).to_stdout_from_any_process
    expect { Legion::Logging.debug('message') }.to_not output(/FATAL/).to_stdout_from_any_process
  end

  it 'can log info' do
    expect { Legion::Logging.info('message') }.to output(/message/).to_stdout_from_any_process
    expect { Legion::Logging.info('message') }.to output(/INFO/).to_stdout_from_any_process

    expect { Legion::Logging.info('message') }.to_not output(/DEBUG/).to_stdout_from_any_process
    expect { Legion::Logging.info('message') }.to_not output(/WARN/).to_stdout_from_any_process
    expect { Legion::Logging.info('message') }.to_not output(/ERROR/).to_stdout_from_any_process
    expect { Legion::Logging.info('message') }.to_not output(/FATAL/).to_stdout_from_any_process
  end

  it 'can log warn' do
    expect { Legion::Logging.warn('message') }.to output(/message/).to_stdout_from_any_process
    expect { Legion::Logging.warn('message') }.to output(/WARN/).to_stdout_from_any_process

    expect { Legion::Logging.warn('message') }.to_not output(/DEBUG/).to_stdout_from_any_process
    expect { Legion::Logging.warn('message') }.to_not output(/INFO/).to_stdout_from_any_process
    expect { Legion::Logging.warn('message') }.to_not output(/ERROR/).to_stdout_from_any_process
    expect { Legion::Logging.warn('message') }.to_not output(/FATAL/).to_stdout_from_any_process
  end

  it 'can log error' do
    expect { Legion::Logging.error('message') }.to output(/message/).to_stdout_from_any_process
    expect { Legion::Logging.error('message') }.to output(/ERROR/).to_stdout_from_any_process

    expect { Legion::Logging.error('message') }.to_not output(/DEBUG/).to_stdout_from_any_process
    expect { Legion::Logging.error('message') }.to_not output(/INFO/).to_stdout_from_any_process
    expect { Legion::Logging.error('message') }.to_not output(/WARN/).to_stdout_from_any_process
    expect { Legion::Logging.error('message') }.to_not output(/FATAL/).to_stdout_from_any_process
  end

  it 'can log fatal' do
    expect { Legion::Logging.fatal('message') }.to output(/message/).to_stdout_from_any_process
    expect { Legion::Logging.fatal('message') }.to output(/FATAL/).to_stdout_from_any_process

    expect { Legion::Logging.fatal('message') }.to_not output(/DEBUG/).to_stdout_from_any_process
    expect { Legion::Logging.fatal('message') }.to_not output(/INFO/).to_stdout_from_any_process
    expect { Legion::Logging.fatal('message') }.to_not output(/WARN/).to_stdout_from_any_process
    expect { Legion::Logging.fatal('message') }.to_not output(/ERROR/).to_stdout_from_any_process
  end

  it 'has a level' do
    expect(Legion::Logging.level).to eq 0
  end

  it 'can start with trace' do
    expect { Legion::Logging::Logger.new(level: 'trace') }.not_to raise_exception
  end

  before do
    @logger = Legion::Logging::Logger.new(level: 'debug', lex: 'foobar', trace: true, extended: true)
  end
  it 'can log with lex name' do
    expect { @logger.fatal('message') }.to output(/message/).to_stdout_from_any_process
  end

  it 'can run setup' do
    expect { Legion::Logging.setup(level: 'info', color: true) }.not_to raise_exception
  end

  it 'can set with log level nil' do
    expect { Legion::Logging::Logger.new(level: nil) }.not_to raise_exception
    expect { Legion::Logging::Logger.new(level: 'fewlkjf') }.not_to raise_exception
  end

  describe '.register_category' do
    before { Legion::Logging::CategoryRegistry.clear! }

    it 'registers a category via the top-level module' do
      Legion::Logging.register_category('security.finding', description: 'Security findings')
      expect(Legion::Logging::CategoryRegistry.category_registered?('security.finding')).to be true
    end

    it 'returns the registered name' do
      result = Legion::Logging.register_category('agent.execution')
      expect(result).to eq('agent.execution')
    end
  end

  describe '.registered_categories' do
    before { Legion::Logging::CategoryRegistry.clear! }

    it 'returns an empty hash when nothing is registered' do
      expect(Legion::Logging.registered_categories).to eq({})
    end

    it 'returns registered categories after registration' do
      Legion::Logging.register_category('task.complete')
      expect(Legion::Logging.registered_categories).to have_key('task.complete')
    end
  end
end
