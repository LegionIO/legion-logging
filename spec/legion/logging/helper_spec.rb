# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Logging::Helper do
  let(:segmented_class) do
    Class.new do
      include Legion::Logging::Helper

      def segments
        %w[microsoft_teams]
      end
    end
  end

  let(:lex_filename_class) do
    Class.new do
      include Legion::Logging::Helper

      def lex_filename
        'microsoft_teams'
      end
    end
  end

  let(:bare_class) do
    stub_const('Legion::Extensions::MyExtension::Runners::Foo', Class.new do
      include Legion::Logging::Helper
    end)
  end

  describe '#log' do
    context 'when the object responds to :segments' do
      subject { segmented_class.new }

      it 'builds a logger with lex_segments:' do
        logger_double = instance_double(Legion::Logging::Logger)
        expect(Legion::Logging::Logger).to receive(:new)
          .with(hash_including(lex_segments: %w[microsoft_teams]))
          .and_return(logger_double)
        expect(subject.log).to eq(logger_double)
      end
    end

    context 'when the object responds to :lex_filename but not :segments' do
      subject { lex_filename_class.new }

      it 'builds a logger with lex: from lex_filename' do
        logger_double = instance_double(Legion::Logging::Logger)
        expect(Legion::Logging::Logger).to receive(:new)
          .with(hash_including(lex: 'microsoft_teams'))
          .and_return(logger_double)
        expect(subject.log).to eq(logger_double)
      end
    end

    context 'when the object has neither segments nor lex_filename' do
      subject { bare_class.new }

      it 'derives tag from class name' do
        logger_double = instance_double(Legion::Logging::Logger)
        expect(Legion::Logging::Logger).to receive(:new)
          .with(hash_including(lex: 'my_extension'))
          .and_return(logger_double)
        expect(subject.log).to eq(logger_double)
      end
    end

    context 'when the object has settings with logger config' do
      subject do
        Class.new do
          include Legion::Logging::Helper

          def settings
            { logger: { level: 'debug', extended: true } }
          end
        end.new
      end

      it 'passes logger settings through' do
        logger_double = instance_double(Legion::Logging::Logger)
        expect(Legion::Logging::Logger).to receive(:new)
          .with(hash_including(level: 'debug', extended: true))
          .and_return(logger_double)
        subject.log
      end
    end

    it 'memoizes the logger instance' do
      obj = segmented_class.new
      first = obj.log
      expect(obj.log).to equal(first)
    end
  end
end
