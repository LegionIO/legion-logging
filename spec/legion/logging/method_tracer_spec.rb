# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Logging::MethodTracer do
  let(:sample_class) do
    Class.new do
      def greet(name)
        "Hello, #{name}"
      end

      def no_args
        :ok
      end
    end
  end

  after do
    described_class.detach_all
  end

  describe '.attach' do
    context 'when ENABLED is false (default)' do
      it 'does not attach a TracePoint' do
        described_class.attach(sample_class)
        expect(described_class::ATTACHED).not_to have_key(sample_class)
      end
    end

    context 'when ENABLED is true' do
      before { stub_const('Legion::Logging::MethodTracer::ENABLED', true) }

      it 'stores the TracePoint in ATTACHED keyed by base' do
        described_class.attach(sample_class)
        expect(described_class::ATTACHED).to have_key(sample_class)
        expect(described_class::ATTACHED[sample_class]).to be_a(TracePoint)
      end

      it 'is idempotent — attaching twice does not add a second TracePoint' do
        described_class.attach(sample_class)
        first_tp = described_class::ATTACHED[sample_class]
        described_class.attach(sample_class)
        expect(described_class::ATTACHED[sample_class]).to equal(first_tp)
        expect(described_class::ATTACHED.count { |k, _| k == sample_class }).to eq(1)
      end

      it 'prints call/return output for a method with parameters' do
        described_class.attach(sample_class)
        obj = sample_class.new
        output = capture_output { obj.greet('world') }
        expect(output).to include('-> greet')
        expect(output).to include('<- greet')
        expect(output).to include('name=')
      end

      it 'omits the params segment when a method has no parameters' do
        described_class.attach(sample_class)
        obj = sample_class.new
        output = capture_output { obj.no_args }
        expect(output).to include('-> no_args')
        expect(output).not_to match(/-> no_args,\s*,/)
        expect(output).not_to match(/-> no_args, $/)
      end

      it 'uses indentation based on call depth' do
        nested_class = Class.new do
          def outer
            inner
          end

          def inner
            :done
          end
        end
        described_class.attach(nested_class)
        obj = nested_class.new
        output = capture_output { obj.outer }
        lines = output.lines
        outer_call = lines.find { |l| l.include?('-> outer') }
        inner_call = lines.find { |l| l.include?('-> inner') }
        expect(outer_call).to start_with('->')
        expect(inner_call).to start_with('  ->')
      end
    end
  end

  describe '.detach' do
    before { stub_const('Legion::Logging::MethodTracer::ENABLED', true) }

    it 'removes and disables the TracePoint for the given base' do
      described_class.attach(sample_class)
      expect(described_class::ATTACHED).to have_key(sample_class)
      described_class.detach(sample_class)
      expect(described_class::ATTACHED).not_to have_key(sample_class)
    end

    it 'is a no-op when base was never attached' do
      expect { described_class.detach(sample_class) }.not_to raise_error
    end
  end

  describe '.detach_all' do
    before { stub_const('Legion::Logging::MethodTracer::ENABLED', true) }

    it 'clears all attached TracePoints' do
      other_class = Class.new
      described_class.attach(sample_class)
      described_class.attach(other_class)
      expect(described_class::ATTACHED.size).to eq(2)
      described_class.detach_all
      expect(described_class::ATTACHED).to be_empty
    end
  end

  describe '.format_params' do
    it 'returns an empty array for a method with no parameters' do
      tp_double = instance_double(TracePoint, parameters: [])
      expect(described_class.format_params(tp_double)).to eq([])
    end

    it 'formats required and optional positional parameters' do
      binding_double = double('binding')
      allow(binding_double).to receive(:local_variable_get).with(:name).and_return('Alice')
      tp_double = instance_double(TracePoint, parameters: [%i[req name]], binding: binding_double)
      result = described_class.format_params(tp_double)
      expect(result).to eq(['name="Alice"'])
    end

    it 'formats keyword parameters' do
      binding_double = double('binding')
      allow(binding_double).to receive(:local_variable_get).with(:key).and_return(42)
      tp_double = instance_double(TracePoint, parameters: [%i[keyreq key]], binding: binding_double)
      result = described_class.format_params(tp_double)
      expect(result).to eq(['key: 42'])
    end

    it 'returns ? when the local variable cannot be retrieved' do
      binding_double = double('binding')
      allow(binding_double).to receive(:local_variable_get).and_raise(NameError)
      tp_double = instance_double(TracePoint, parameters: [%i[req x]], binding: binding_double)
      result = described_class.format_params(tp_double)
      expect(result).to eq(['x="?"'])
    end
  end

  # Helper to capture stdout output from puts calls inside a block
  def capture_output
    old_stdout = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = old_stdout
  end
end
