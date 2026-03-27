# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Legion::Logging.log_exception' do
  let(:error) do
    raise TypeError, 'wrong argument type'
  rescue TypeError => e
    e
  end

  before do
    Legion::Logging.exception_writer = nil
    Legion::Logging.setup(level: 'debug', format: :text, async: false) unless Legion::Logging.log
  end

  it 'logs the error message to stdout/file at the given level' do
    expect(Legion::Logging.log).to receive(:error).with(kind_of(String)).and_call_original
    Legion::Logging.log_exception(error)
  end

  it 'calls exception_writer with full event' do
    captured = nil
    Legion::Logging.exception_writer = lambda { |event, routing_key:, headers:, properties:|
      captured = { event: event, routing_key: routing_key, headers: headers, properties: properties }
    }
    Legion::Logging.log_exception(error, lex: 'eval', component_type: :transport, gem_name: 'lex-eval')
    expect(captured).not_to be_nil
    expect(captured[:event][:exception_class]).to eq('TypeError')
    expect(captured[:event][:backtrace]).to be_an(Array)
    expect(captured[:event][:error_fingerprint]).to match(/\A[0-9a-f]{32}\z/)
  end

  it 'builds routing key from level, lex, and component_type' do
    captured = nil
    Legion::Logging.exception_writer = lambda { |_event, routing_key:, **|
      captured = routing_key
    }
    Legion::Logging.log_exception(error, level: :fatal, lex: 'synapse', component_type: :runner)
    expect(captured).to eq('legion.logging.exception.fatal.synapse.runner')
  end

  it 'includes headers with fingerprint and exception_class' do
    captured = nil
    Legion::Logging.exception_writer = lambda { |_event, headers:, **|
      captured = headers
    }
    Legion::Logging.log_exception(error, lex: 'eval', gem_name: 'lex-eval', lex_version: '0.3.0')
    expect(captured['x-error-fingerprint']).to match(/\A[0-9a-f]{32}\z/)
    expect(captured['x-exception-class']).to eq('TypeError')
    expect(captured['x-gem-name']).to eq('lex-eval')
  end

  it 'includes AMQP properties' do
    captured = nil
    Legion::Logging.exception_writer = lambda { |_event, properties:, **|
      captured = properties
    }
    Legion::Logging.log_exception(error)
    expect(captured[:content_type]).to eq('application/json')
    expect(captured[:type]).to eq('exception_event')
    expect(captured[:delivery_mode]).to eq(2)
    expect(captured[:message_id]).to match(/\A[0-9a-f-]{36}\z/)
  end

  it 'defaults level to :error' do
    captured = nil
    Legion::Logging.exception_writer = lambda { |event, **|
      captured = event[:level]
    }
    Legion::Logging.log_exception(error)
    expect(captured).to eq(:error)
  end

  it 'defaults lex to core and component_type to unknown' do
    captured = nil
    Legion::Logging.exception_writer = lambda { |_event, routing_key:, **|
      captured = routing_key
    }
    Legion::Logging.log_exception(error)
    expect(captured).to eq('legion.logging.exception.error.core.unknown')
  end

  it 'uses :fatal level for fatal exceptions' do
    captured = nil
    Legion::Logging.exception_writer = lambda { |_event, routing_key:, **|
      captured = routing_key
    }
    Legion::Logging.log_exception(error, level: :fatal)
    expect(captured).to start_with('legion.logging.exception.fatal.')
  end

  it 'passes handled flag through' do
    captured = nil
    Legion::Logging.exception_writer = lambda { |event, **|
      captured = event[:handled]
    }
    Legion::Logging.log_exception(error, handled: true)
    expect(captured).to be true
  end

  it 'includes task_id when provided' do
    captured = nil
    Legion::Logging.exception_writer = lambda { |event, **|
      captured = event[:task_id]
    }
    Legion::Logging.log_exception(error, task_id: 42)
    expect(captured).to eq(42)
  end

  it 'includes user identity' do
    captured = nil
    Legion::Logging.exception_writer = lambda { |event, **|
      captured = event[:user]
    }
    Legion::Logging.log_exception(error)
    expect(captured).to eq(ENV.fetch('USER', nil))
  end
end
