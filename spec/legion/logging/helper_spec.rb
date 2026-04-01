# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Logging::Helper do
  let(:bare_class) do
    stub_const('Legion::Extensions::MyExtension::Runners::Foo', Class.new do
      include Legion::Logging::Helper
    end)
  end

  let(:lex_filename_class) do
    Class.new do
      include Legion::Logging::Helper

      def lex_filename
        'microsoft_teams'
      end
    end
  end

  let(:settings_class) do
    Class.new do
      include Legion::Logging::Helper

      def settings
        { logger: { level: 'debug', trace: true, extended: true } }
      end
    end
  end

  describe '#log' do
    it 'returns a TaggedLogger' do
      expect(bare_class.new.log).to be_a(Legion::Logging::TaggedLogger)
    end

    it 'derives segments from class namespace' do
      logger = bare_class.new.log
      expect(logger.segments).to eq(%w[my_extension runners foo])
    end

    it 'uses default settings when no override is defined' do
      logger = bare_class.new.log
      expect(logger.level).to eq(1)
      expect(logger.extended).to be false
      expect(logger.trace_enabled).to be false
    end

    it 'uses overridden settings when defined' do
      logger = settings_class.new.log
      expect(logger.level).to eq(0)
      expect(logger.extended).to be true
      expect(logger.trace_enabled).to be true
    end

    it 'memoizes the logger instance' do
      obj = bare_class.new
      first = obj.log
      expect(obj.log).to equal(first)
    end
  end

  describe '#with_log_context' do
    subject { bare_class.new }

    it 'sets the thread-local method name during the block' do
      captured = nil
      subject.with_log_context(:my_method) do
        captured = Legion::Logging::Helper.current_log_method
      end
      expect(captured).to eq('my_method')
    end

    it 'restores the previous value after the block' do
      subject.with_log_context(:outer) do
        subject.with_log_context(:inner) do
          expect(Legion::Logging::Helper.current_log_method).to eq('inner')
        end
        expect(Legion::Logging::Helper.current_log_method).to eq('outer')
      end
      expect(Legion::Logging::Helper.current_log_method).to be_nil
    end

    it 'restores on exception' do
      subject.with_log_context(:safe) do
        raise 'boom'
      end
    rescue RuntimeError
      nil
    ensure
      expect(Legion::Logging::Helper.current_log_method).to be_nil
    end
  end

  describe '#handle_exception' do
    subject { bare_class.new }

    let(:underlying_logger) { instance_double(Logger) }

    before do
      allow(Legion::Logging).to receive(:log).and_return(underlying_logger)
      allow(Legion::Logging).to receive(:color).and_return(false)
      allow(Legion::Logging).to receive(:warn)
      allow(Legion::Logging).to receive(:exception_writer).and_return(->(_e, **_k) {})
      allow(underlying_logger).to receive(:error)
      allow(underlying_logger).to receive(:fatal)
    end

    it 'writes human-readable output to the underlying logger' do
      exc = StandardError.new('test error')
      subject.handle_exception(exc)
      expect(underlying_logger).to have_received(:error).with(/StandardError: test error/)
    end

    it 'includes backtrace in output' do
      exc = StandardError.new('test error')
      exc.set_backtrace(['/app/lib/foo.rb:42:in `bar`', '/app/lib/baz.rb:10:in `run`'])
      subject.handle_exception(exc)
      expect(underlying_logger).to have_received(:error).with(%r{/app/lib/foo.rb:42})
    end

    it 'includes context line with task_id' do
      exc = StandardError.new('test error')
      subject.handle_exception(exc, task_id: 12_345)
      expect(underlying_logger).to have_received(:error).with(/task:12345/)
    end

    it 'reads task_id from thread context when not passed explicitly' do
      exc = StandardError.new('test error')
      Thread.current[:legion_context] = { task_id: 99, conversation_id: 'conv-abc' }
      subject.handle_exception(exc)
      expect(underlying_logger).to have_received(:error).with(/task:99/)
      expect(underlying_logger).to have_received(:error).with(/conversation:conv-abc/)
    ensure
      Thread.current[:legion_context] = nil
    end

    it 'explicit task_id wins over thread context' do
      exc = StandardError.new('test error')
      Thread.current[:legion_context] = { task_id: 99 }
      subject.handle_exception(exc, task_id: 42)
      expect(underlying_logger).to have_received(:error).with(/task:42/)
    ensure
      Thread.current[:legion_context] = nil
    end

    it 'publishes structured event via exception_writer' do
      writer = instance_double(Proc)
      allow(writer).to receive(:call)
      allow(Legion::Logging).to receive(:exception_writer).and_return(writer)

      exc = StandardError.new('publish test')
      subject.handle_exception(exc)

      expect(writer).to have_received(:call).with(
        hash_including(exception_class: 'StandardError'),
        routing_key: /legion\.logging\.exception\.error/,
        headers:     hash_including('x-exception-class' => 'StandardError'),
        properties:  hash_including(type: 'exception_event')
      )
    end

    it 'caps backtrace at EXCEPTION_BACKTRACE_LIMIT' do
      exc = StandardError.new('deep stack')
      exc.set_backtrace(Array.new(25) { |i| "/app/lib/file.rb:#{i}:in `method_#{i}`" })
      subject.handle_exception(exc)
      expect(underlying_logger).to have_received(:error).with(/\.\.\. 15 more/)
    end

    it 'supports custom log level' do
      exc = StandardError.new('fatal error')
      subject.handle_exception(exc, level: :fatal)
      expect(underlying_logger).to have_received(:fatal).with(/StandardError: fatal error/)
    end

    context 'with color enabled' do
      around do |example|
        was_enabled = Rainbow.enabled
        Rainbow.enabled = true
        example.run
      ensure
        Rainbow.enabled = was_enabled
      end

      before do
        allow(Legion::Logging).to receive(:color).and_return(true)
      end

      it 'applies rainbow coloring to exception output' do
        exc = StandardError.new('colored error')
        exc.set_backtrace(['/app/lib/foo.rb:42:in `bar`'])
        subject.handle_exception(exc)
        expect(underlying_logger).to have_received(:error) do |msg|
          expect(msg).to include("\e[") # contains ANSI escape codes
        end
      end
    end
  end

  describe '.current_log_method' do
    it 'returns nil when no context is set' do
      expect(Legion::Logging::Helper.current_log_method).to be_nil
    end
  end

  describe '.current_log_segments' do
    it 'returns nil when no segments are set' do
      expect(Legion::Logging::Helper.current_log_segments).to be_nil
    end
  end

  describe '.current_context' do
    it 'returns nil when no context is set' do
      expect(Legion::Logging::Helper.current_context).to be_nil
    end

    it 'returns the thread-local context hash' do
      Thread.current[:legion_context] = { task_id: 1 }
      expect(Legion::Logging::Helper.current_context).to eq({ task_id: 1 })
    ensure
      Thread.current[:legion_context] = nil
    end
  end

  describe 'derive_log_segments (via TaggedLogger segments)' do
    it 'strips Legion and Extensions from namespace' do
      logger = bare_class.new.log
      expect(logger.segments).to eq(%w[my_extension runners foo])
    end

    it 'handles core library namespaces' do
      core_class = stub_const('Legion::LLM::Router', Class.new do
        include Legion::Logging::Helper
      end)
      logger = core_class.new.log
      expect(logger.segments).to eq(%w[llm router])
    end

    it 'caches segments per class' do
      obj1 = bare_class.new
      obj2 = bare_class.new
      expect(obj1.log.segments).to equal(obj2.log.segments)
    end
  end

  describe '#log_name' do
    it 'uses lex_filename when available' do
      obj = lex_filename_class.new
      expect(obj.send(:log_name)).to eq('microsoft_teams')
    end

    it 'falls back to first segment' do
      obj = bare_class.new
      expect(obj.send(:log_name)).to eq('my_extension')
    end
  end

  describe '#gem_name' do
    it 'returns nil when no gem is found' do
      obj = bare_class.new
      expect(obj.send(:gem_name)).to be_nil
    end
  end

  describe 'default settings' do
    it 'returns Legion::Logging::Settings.default when Legion::Settings is not defined' do
      obj = bare_class.new
      expected = Legion::Logging::Settings.default
      expect(obj.send(:settings)).to eq({ logger: expected })
    end
  end
end
