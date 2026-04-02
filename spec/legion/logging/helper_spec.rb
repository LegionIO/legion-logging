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

  let(:component_level_class) do
    Class.new do
      include Legion::Logging::Helper

      def settings
        { log_level: 'warn', logger: { level: 'error', trace: true, extended: true } }
      end
    end
  end

  let(:legacy_component_level_class) do
    Class.new do
      include Legion::Logging::Helper

      def settings
        { logger_level: 'info', logger: { trace: true, extended: true } }
      end
    end
  end

  let(:component_options_class) do
    Class.new do
      include Legion::Logging::Helper

      def settings
        { trace: false, trace_size: 7, extended: false, logger: { trace: true, trace_size: 2, extended: true } }
      end
    end
  end

  let(:transport_class) do
    stub_const('Legion::Transport::HelperProbe', Class.new do
      include Legion::Logging::Helper
    end)
  end

  let(:extension_settings_helper_class) do
    stub_const('Legion::Extensions::MicrosoftTeams::Transport::Probe', Class.new do
      include Legion::Logging::Helper

      def lex_filename
        'microsoft_teams'
      end

      def settings
        {}
      end
    end)
  end

  describe '#log' do
    before do
      Legion::Logging.setup(level: 'debug', async: false, color: false)
    end

    it 'returns a TaggedLogger' do
      expect(bare_class.new.log).to be_a(Legion::Logging::TaggedLogger)
    end

    it 'passes only tagged-logger supported options to TaggedLogger' do
      fake_logger = instance_double(
        Legion::Logging::TaggedLogger,
        segments:      %w[my_extension runners foo],
        level:         0,
        extended:      true,
        trace_enabled: true
      )

      expect(Legion::Logging::TaggedLogger).to receive(:new) do |**kwargs|
        expect(kwargs.keys).to contain_exactly(:segments, :level, :trace, :trace_size, :extended)
        fake_logger
      end

      expect(bare_class.new.log).to eq(fake_logger)
    end

    it 'derives segments from class namespace' do
      logger = bare_class.new.log
      expect(logger.segments).to eq(%w[my_extension runners foo])
    end

    it 'uses default settings when no override is defined' do
      logger = bare_class.new.log
      runtime = Legion::Logging.current_settings
      expect(logger.level).to eq(Legion::Logging::TaggedLogger::LEVELS.fetch(runtime[:level].to_sym))
      expect(logger.extended).to be(runtime[:extended])
      expect(logger.trace_enabled).to be(runtime[:trace])
    end

    it 'uses overridden settings when defined' do
      logger = settings_class.new.log
      expect(logger.level).to eq(0)
      expect(logger.extended).to be true
      expect(logger.trace_enabled).to be true
    end

    it 'uses a component log_level from the local settings hash' do
      logger = component_level_class.new.log
      expect(logger.level).to eq(Legion::Logging::TaggedLogger::LEVELS[:warn])
      expect(logger.extended).to be true
      expect(logger.trace_enabled).to be true
    end

    it 'supports legacy component logger_level settings' do
      logger = legacy_component_level_class.new.log
      expect(logger.level).to eq(Legion::Logging::TaggedLogger::LEVELS[:info])
      expect(logger.extended).to be true
      expect(logger.trace_enabled).to be true
    end

    it 'uses component trace, trace_size, and extended settings when provided' do
      logger = component_options_class.new.log
      expect(logger.trace_enabled).to be false
      expect(logger.extended).to be false
      expect(logger.instance_variable_get(:@trace_size)).to eq(7)
    end

    it 'memoizes the logger instance' do
      obj = bare_class.new
      first = obj.log
      expect(obj.log).to equal(first)
    end

    it 'refreshes a memoized logger when Legion::Logging is reconfigured' do
      obj = bare_class.new
      first = obj.log

      Legion::Logging.setup(level: 'info', async: false, color: false)
      second = obj.log

      expect(second).not_to equal(first)
      expect(second.level).to eq(Legion::Logging::TaggedLogger::LEVELS[:info])
    end

    it 'prefers runtime Legion::Logging settings over loaded global settings' do
      stub_const('Legion::Settings', Module.new do
        def self.loaded? = true

        def self.[](key)
          return { level: 'info', trace: true, extended: true } if key == :logging

          nil
        end
      end)

      logger = bare_class.new.log

      expect(logger.level).to eq(0)
    end

    it 'uses top-level Legion::Settings component log_level when no local settings method exists' do
      stub_const('Legion::Settings', Module.new do
        def self.loaded? = true

        def self.[](key)
          return { log_level: 'error', logger: { trace: false } } if key == :transport
          return { level: 'info', trace: true, extended: true } if key == :logging

          nil
        end

        def self.dig(*)
          nil
        end
      end)

      logger = transport_class.new.log

      expect(logger.level).to eq(Legion::Logging::TaggedLogger::LEVELS[:error])
      expect(logger.trace_enabled).to be false
    end

    it 'uses Legion::Settings extension log_level for lex-style components' do
      stub_const('Legion::Settings', Module.new do
        def self.loaded? = true

        def self.[](key)
          return nil unless key == :microsoft_teams

          nil
        end

        def self.dig(*keys)
          return { log_level: 'warn', logger: { extended: false } } if keys == %i[extensions microsoft_teams]

          nil
        end
      end)

      logger = lex_filename_class.new.log

      expect(logger.level).to eq(Legion::Logging::TaggedLogger::LEVELS[:warn])
      expect(logger.extended).to be false
    end

    it 'uses global logging settings for lex-style components without explicit extension logger config' do
      stub_const('Legion::Settings', Module.new do
        def self.loaded? = true

        def self.[](key)
          return { level: 'debug', trace: true, trace_size: 8, extended: true } if key == :logging
          return {} if key == :extensions

          nil
        end

        def self.dig(*keys)
          return nil if keys == %i[extensions microsoft_teams]

          nil
        end
      end)
      allow(Legion::Logging).to receive(:current_settings).and_return({})

      logger = extension_settings_helper_class.new.log

      expect(logger.level).to eq(Legion::Logging::TaggedLogger::LEVELS[:debug])
      expect(logger.trace_enabled).to be true
      expect(logger.extended).to be true
      expect(logger.instance_variable_get(:@trace_size)).to eq(8)
    end

    it 'uses global trace, trace_size, and extended settings when no component override exists' do
      stub_const('Legion::Settings', Module.new do
        def self.loaded? = true

        def self.[](key)
          return { level: 'info', trace: false, trace_size: 11, extended: false } if key == :logging

          nil
        end

        def self.dig(*)
          nil
        end
      end)
      allow(Legion::Logging).to receive(:current_settings).and_return({})

      logger = bare_class.new.log

      expect(logger.trace_enabled).to be false
      expect(logger.extended).to be false
      expect(logger.instance_variable_get(:@trace_size)).to eq(11)
    end

    it 'prefers runtime trace, trace_size, and extended settings over loaded global settings' do
      stub_const('Legion::Settings', Module.new do
        def self.loaded? = true

        def self.[](key)
          return { level: 'info', trace: true, trace_size: 4, extended: true } if key == :logging

          nil
        end

        def self.dig(*)
          nil
        end
      end)
      allow(Legion::Logging).to receive(:current_settings).and_return(
        level: 'debug', trace: false, trace_size: 12, extended: false
      )

      logger = bare_class.new.log

      expect(logger.trace_enabled).to be false
      expect(logger.extended).to be false
      expect(logger.instance_variable_get(:@trace_size)).to eq(12)
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

    context 'without structured exception support' do
      before do
        hide_const('Legion::Logging::EventBuilder')
      end

      it 'still writes a human-readable exception line' do
        exc = StandardError.new('fallback error')
        subject.handle_exception(exc)
        expect(underlying_logger).to have_received(:error).with(/StandardError: fallback error/)
      end
    end
  end

  describe 'TaggedLogger unknown fallback' do
    it 'still emits unknown messages when Legion::Logging.unknown is unavailable' do
      bare = bare_class.new
      allow(Legion::Logging).to receive(:unknown).and_raise(NoMethodError)
      allow(Legion::Logging).to receive(:respond_to?).and_call_original
      allow(Legion::Logging).to receive(:respond_to?).with(:unknown).and_return(false)

      expect { bare.log.unknown('purple test') }.to output(/purple test/).to_stdout_from_any_process
    end
  end

  describe 'TaggedLogger component-level emission' do
    let(:debug_component_class) do
      Class.new do
        include Legion::Logging::Helper

        def settings
          { log_level: 'debug' }
        end
      end
    end

    it 'emits debug output when the component log level is lower than the global log level' do
      Legion::Logging.setup(level: 'info', async: false, color: false)
      logger = debug_component_class.new.log

      expect { logger.debug('component debug probe') }.to output(/component debug probe/).to_stdout_from_any_process
      expect { logger.debug('component debug probe') }.to output(/DEBUG/).to_stdout_from_any_process
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
      Legion::Logging.instance_variable_set(:@current_settings, nil)
      obj = bare_class.new
      expected = Legion::Logging::Settings.default
      expect(obj.send(:global_logger_settings)).to eq(expected)
      expect(obj.send(:resolve_logger_settings)).to eq(expected)
    end
  end

  describe 'TaggedLogger defaults' do
    it 'matches Legion::Logging::Settings.default for direct instantiation' do
      logger = Legion::Logging::TaggedLogger.new(segments: %w[direct])
      defaults = Legion::Logging::Settings.default

      expect(logger.level).to eq(Legion::Logging::TaggedLogger::LEVELS.fetch(defaults[:level]))
      expect(logger.trace_enabled).to be(defaults[:trace])
      expect(logger.extended).to be(defaults[:extended])
      expect(logger.instance_variable_get(:@trace_size)).to eq(defaults[:trace_size])
    end
  end
end
