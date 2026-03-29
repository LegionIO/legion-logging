# frozen_string_literal: true

require 'legion/logging'
require 'legion/logging/event_builder'

RSpec.describe Legion::Logging::EventBuilder do
  describe '.build' do
    it 'includes required fields' do
      event = described_class.build(level: :fatal, message: 'something broke')
      expect(event[:timestamp]).to be_a(String)
      expect(event[:level]).to eq(:fatal)
      expect(event[:message]).to eq('something broke')
      expect(event[:pid]).to eq(Process.pid)
      expect(event[:thread]).to eq(Thread.current.object_id)
    end

    it 'includes lex source from string' do
      event = described_class.build(level: :error, message: 'fail', lex: 'slack')
      expect(event[:lex]).to eq('slack')
    end

    it 'includes lex source from segments' do
      event = described_class.build(level: :error, message: 'fail', lex_segments: %w[agentic memory])
      expect(event[:lex]).to eq('agentic-memory')
    end

    it 'sets lex to nil for core (no lex context)' do
      event = described_class.build(level: :fatal, message: 'fail')
      expect(event[:lex]).to be_nil
    end

    it 'extracts exception details when message is an Exception' do
      exc = NoMethodError.new("undefined method 'foo'")
      exc.set_backtrace(['/path/to/file.rb:42:in `method_name`'])
      event = described_class.build(level: :fatal, message: exc)
      expect(event[:exception][:class]).to eq('NoMethodError')
      expect(event[:exception][:message]).to eq("undefined method 'foo'")
      expect(event[:message]).to eq("undefined method 'foo'")
      expect(event[:backtrace]).to eq(['/path/to/file.rb:42:in `method_name`'])
    end

    it 'includes caller location' do
      event = described_class.build(level: :error, message: 'fail')
      expect(event[:caller]).to be_a(Hash)
      expect(event[:caller][:file]).to be_a(String)
      expect(event[:caller][:function]).to be_a(String)
      expect(event[:caller][:line]).to be_a(Integer)
    end

    it 'includes node name when Legion::Settings is available' do
      stub_const('Legion::Settings', double)
      allow(Legion::Settings).to receive(:[]).with(:client).and_return({ name: 'test-node' })
      event = described_class.build(level: :fatal, message: 'fail')
      expect(event[:node]).to eq('test-node')
    end

    it 'omits node when Legion::Settings is not available' do
      hide_const('Legion::Settings') if defined?(Legion::Settings)
      event = described_class.build(level: :fatal, message: 'fail')
      expect(event).not_to have_key(:node)
    end

    it 'includes gem info when gem spec is found via lex- prefix' do
      spec = double(name: 'lex-slack', version: Gem::Version.new('0.3.0'),
                    full_gem_path: '/path/to/lex-slack',
                    metadata: { 'source_code_uri' => 'https://github.com/LegionIO/lex-slack',
                                'homepage_uri'    => 'https://github.com/LegionIO/lex-slack' },
                    homepage: 'https://github.com/LegionIO/lex-slack')
      allow(Gem::Specification).to receive(:find_by_name).with('slack').and_raise(Gem::MissingSpecError.new('slack', []))
      allow(Gem::Specification).to receive(:find_by_name).with('lex-slack').and_return(spec)
      event = described_class.build(level: :error, message: 'fail', lex: 'slack')
      expect(event[:gem][:name]).to eq('lex-slack')
      expect(event[:gem][:version]).to eq('0.3.0')
    end

    it 'includes gem info when gem spec is found via legion- prefix' do
      spec = double(name: 'legion-data', version: Gem::Version.new('1.5.0'),
                    full_gem_path: '/path/to/legion-data',
                    metadata: { 'source_code_uri' => 'https://github.com/LegionIO/legion-data',
                                'homepage_uri'    => 'https://github.com/LegionIO/legion-data' },
                    homepage: 'https://github.com/LegionIO/legion-data')
      allow(Gem::Specification).to receive(:find_by_name).with('data').and_raise(Gem::MissingSpecError.new('data', []))
      allow(Gem::Specification).to receive(:find_by_name).with('lex-data').and_raise(Gem::MissingSpecError.new('lex-data', []))
      allow(Gem::Specification).to receive(:find_by_name).with('legion-data').and_return(spec)
      event = described_class.build(level: :error, message: 'fail', lex: 'data')
      expect(event[:gem][:name]).to eq('legion-data')
      expect(event[:gem][:version]).to eq('1.5.0')
    end

    it 'omits gem info when gem spec is not found under any prefix' do
      allow(Gem::Specification).to receive(:find_by_name).and_raise(Gem::MissingSpecError.new('x', []))
      event = described_class.build(level: :error, message: 'fail', lex: 'nonexistent')
      expect(event).not_to have_key(:gem)
    end

    it 'passes through context opts' do
      event = described_class.build(level: :error, message: 'fail',
                                    context: { task_id: 'abc-123', runner_class: 'Foo' })
      expect(event[:context][:task_id]).to eq('abc-123')
    end

    it 'strips ANSI escape codes from messages' do
      event = described_class.build(level: :error, message: "\e[31mred error\e[0m")
      expect(event[:message]).to eq('red error')
    end

    it 'includes category when provided' do
      event = described_class.build(level: :info, message: 'finding detected', category: 'security.finding')
      expect(event[:category]).to eq('security.finding')
    end

    it 'includes category when provided as a symbol' do
      event = described_class.build(level: :info, message: 'agent done', category: :'agent.execution')
      expect(event[:category]).to eq('agent.execution')
    end

    it 'omits category key when category is nil' do
      event = described_class.build(level: :info, message: 'no category')
      expect(event).not_to have_key(:category)
    end

    it 'does not affect other fields when category is present' do
      event = described_class.build(level: :warn, message: 'check this', category: 'net.connect')
      expect(event[:level]).to eq(:warn)
      expect(event[:message]).to eq('check this')
      expect(event[:category]).to eq('net.connect')
    end
  end

  describe '.build_exception' do
    let(:exception) do
      exc = RuntimeError.new('something went wrong')
      exc.set_backtrace([
                          '/gems/legion-data-1.6.9/lib/legion/data.rb:42:in `connect`',
                          '/gems/lex-apollo-0.4.14/lib/lex/apollo/runner.rb:17:in `call`',
                          '/app/lib/main.rb:5:in `<main>`'
                        ])
      exc
    end

    it 'includes exception_class as top-level key' do
      event = described_class.build_exception(exception: exception, level: :error)
      expect(event[:exception_class]).to eq('RuntimeError')
    end

    it 'includes message from exception' do
      event = described_class.build_exception(exception: exception, level: :error)
      expect(event[:message]).to eq('something went wrong')
    end

    it 'includes backtrace as Array' do
      event = described_class.build_exception(exception: exception, level: :error)
      expect(event[:backtrace]).to be_an(Array)
      expect(event[:backtrace]).not_to be_empty
    end

    it 'includes flat caller fields from backtrace' do
      event = described_class.build_exception(exception: exception, level: :error)
      expect(event[:caller_file]).to be_a(String)
      expect(event[:caller_line]).to be_an(Integer)
      expect(event[:caller_function]).to be_a(String)
    end

    it 'includes lex and component_type' do
      event = described_class.build_exception(exception: exception, level: :error,
                                              lex: 'apollo', component_type: 'runner')
      expect(event[:lex]).to eq('apollo')
      expect(event[:component_type]).to eq('runner')
    end

    it 'includes version fields gem_name, lex_version, ruby_version' do
      event = described_class.build_exception(exception: exception, level: :error,
                                              gem_name: 'lex-apollo', lex_version: '0.4.14')
      expect(event[:gem_name]).to eq('lex-apollo')
      expect(event[:lex_version]).to eq('0.4.14')
      expect(event[:ruby_version]).to be_a(String)
      expect(event[:ruby_version]).to include(RUBY_VERSION)
    end

    it 'includes legion_versions hash with only legion-* and lex-* gems' do
      event = described_class.build_exception(exception: exception, level: :error)
      expect(event[:legion_versions]).to be_a(Hash)
      event[:legion_versions].each_key do |name|
        expect(name).to match(/\A(legion-|lex-)/)
      end
    end

    it 'includes error_fingerprint matching 32-char hex' do
      event = described_class.build_exception(exception: exception, level: :error)
      expect(event[:error_fingerprint]).to match(/\A[0-9a-f]{32}\z/)
    end

    it 'produces the same fingerprint for the same error' do
      event1 = described_class.build_exception(exception: exception, level: :error)
      event2 = described_class.build_exception(exception: exception, level: :error)
      expect(event1[:error_fingerprint]).to eq(event2[:error_fingerprint])
    end

    it 'includes handled flag' do
      handled_event   = described_class.build_exception(exception: exception, level: :error, handled: true)
      unhandled_event = described_class.build_exception(exception: exception, level: :error, handled: false)
      expect(handled_event[:handled]).to be true
      expect(unhandled_event[:handled]).to be false
    end

    it 'includes payload_summary when provided' do
      event = described_class.build_exception(exception: exception, level: :error,
                                              payload_summary: { key: 'value' }.to_json)
      expect(event[:payload_summary]).to be_a(String)
    end

    it 'includes identity fields node, pid, thread, timestamp, level' do
      stub_const('Legion::Settings', double)
      allow(Legion::Settings).to receive(:[]).with(:client).and_return({ name: 'test-node' })
      event = described_class.build_exception(exception: exception, level: :error)
      expect(event[:node]).to eq('test-node')
      expect(event[:pid]).to eq(Process.pid)
      expect(event[:thread]).to eq(Thread.current.object_id)
      expect(event[:timestamp]).to be_a(String)
      expect(event[:level]).to eq(:error)
    end

    it 'includes user from ENV when Secret helper is not loaded' do
      hide_const('Legion::Extensions::Helpers::Secret') if defined?(Legion::Extensions::Helpers::Secret)
      event = described_class.build_exception(exception: exception, level: :error)
      expect(event[:user]).to eq(ENV.fetch('USER', nil))
    end

    it 'includes task_id when provided' do
      event = described_class.build_exception(exception: exception, level: :error, task_id: 'abc-123')
      expect(event[:task_id]).to eq('abc-123')
    end

    it 'omits task_id when nil' do
      event = described_class.build_exception(exception: exception, level: :error, task_id: nil)
      expect(event).not_to have_key(:task_id)
    end

    it 'includes conversation_id from Legion::Context session when available' do
      session_double = double(session_id: 'sess-xyz-789')
      context_double = double
      allow(context_double).to receive(:current_session).and_return(session_double)
      stub_const('Legion::Context', context_double)
      event = described_class.build_exception(exception: exception, level: :error)
      expect(event[:conversation_id]).to eq('sess-xyz-789')
    end

    it 'omits conversation_id when no session is active' do
      context_double = double
      allow(context_double).to receive(:current_session).and_return(nil)
      stub_const('Legion::Context', context_double)
      event = described_class.build_exception(exception: exception, level: :error)
      expect(event).not_to have_key(:conversation_id)
    end

    it 'truncates message to 4KB' do
      long_msg = 'x' * 8000
      exc = RuntimeError.new(long_msg)
      exc.set_backtrace(caller)
      event = described_class.build_exception(exception: exc, level: :error)
      expect(event[:message].bytesize).to be <= Legion::Logging::EventBuilder::MAX_MESSAGE_BYTES
    end

    it 'truncates payload_summary to 8KB' do
      large_payload = 'y' * 16_000
      event = described_class.build_exception(exception: exception, level: :error,
                                              payload_summary: large_payload)
      expect(event[:payload_summary].bytesize).to be <= Legion::Logging::EventBuilder::MAX_PAYLOAD_BYTES
    end
  end

  describe '.fingerprint' do
    let(:args) do
      {
        exception_class: 'RuntimeError',
        message:         'object 0x00007f8abc123456 failed',
        caller_file:     '/gems/lex-apollo-0.4.14/lib/lex/apollo/runner.rb',
        caller_line:     42,
        caller_function: 'call',
        gem_name:        'lex-apollo',
        component_type:  'runner',
        backtrace:       [
          '/gems/legion-data-1.6.9/lib/legion/data.rb:10:in `foo`',
          '/gems/lex-apollo-0.4.14/lib/runner.rb:20:in `bar`'
        ]
      }
    end

    it 'returns a 32-char hex digest' do
      result = described_class.fingerprint(**args)
      expect(result).to match(/\A[0-9a-f]{32}\z/)
    end

    it 'strips hex addresses from message before fingerprinting' do
      args_with_hex = args.merge(message: 'object 0x00007f8abc123456 failed')
      args_no_hex   = args.merge(message: 'object 0xXXX failed')
      expect(described_class.fingerprint(**args_with_hex)).to eq(described_class.fingerprint(**args_no_hex))
    end

    it 'strips gem versions from backtrace paths' do
      args_versioned   = args.merge(backtrace: ['/gems/lex-apollo-0.4.14/lib/runner.rb:5:in `x`'])
      args_unversioned = args.merge(backtrace: ['/gems/lex-apollo/lib/runner.rb:5:in `x`'])
      expect(described_class.fingerprint(**args_versioned)).to eq(described_class.fingerprint(**args_unversioned))
    end

    it 'normalizes class names in object references' do
      fp1 = described_class.fingerprint(
        exception_class: 'NoMethodError',
        message: 'undefined method for #<RuntimeError:0x00007f8b>',
        caller_file: 'lib/foo.rb', caller_line: 10,
        caller_function: 'bar', gem_name: 'lex-foo',
        component_type: :runner, backtrace: []
      )
      fp2 = described_class.fingerprint(
        exception_class: 'NoMethodError',
        message: 'undefined method for #<TypeError:0x0000abcd>',
        caller_file: 'lib/foo.rb', caller_line: 10,
        caller_function: 'bar', gem_name: 'lex-foo',
        component_type: :runner, backtrace: []
      )
      expect(fp1).to eq(fp2)
    end
  end
end
