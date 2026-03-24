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
  end
end
