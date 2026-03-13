# frozen_string_literal: true

require 'spec_helper'

require 'legion/logging'

RSpec.describe Legion::Logging do
  before do
    @logger = Legion::Logging::Logger.new(level: 42)
  end

  it 'can log debug' do
    expect { @logger.debug('message') }.to_not output.to_stdout_from_any_process
  end

  it 'can log info' do
    expect { @logger.info('message') }.to_not output.to_stdout_from_any_process
  end

  it 'can log warn' do
    expect { @logger.warn('message') }.to_not output.to_stdout_from_any_process
  end

  it 'can log error' do
    expect { @logger.error('message') }.to_not output.to_stdout_from_any_process
  end

  it 'can log fatal' do
    expect { @logger.fatal('message') }.to_not output.to_stdout_from_any_process
  end

  it 'can log unknown' do
    expect { @logger.unknown('message') }.to_not output.to_stdout_from_any_process
  end

  it 'has a level' do
    expect(@logger.level).to eq nil
  end
end
