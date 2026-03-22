# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Logging::Builder do
  describe '#text_format with lex_segments:' do
    it 'formats lex_segments as stacked brackets' do
      logger = Legion::Logging::Logger.new(lex_segments: %w[agentic cognitive anchor])
      expect { logger.info('hello') }.to output(/\[agentic\]\[cognitive\]\[anchor\]/).to_stdout_from_any_process
      expect { logger.info('hello') }.to output(/hello/).to_stdout_from_any_process
    end

    it 'formats single-segment lex_segments as single bracket' do
      logger = Legion::Logging::Logger.new(lex_segments: %w[node])
      expect { logger.info('hello') }.to output(/\[node\]/).to_stdout_from_any_process
    end

    it 'falls back to legacy lex: string when lex_segments not present' do
      logger = Legion::Logging::Logger.new(lex: 'microsoft_teams')
      expect { logger.info('hello') }.to output(/\[microsoft_teams\]/).to_stdout_from_any_process
    end

    it 'produces no lex bracket when neither lex nor lex_segments present' do
      logger = Legion::Logging::Logger.new
      # Output should not contain a bracket followed immediately by word chars then more of the message
      # i.e. no [something] tag in the line (timestamps are [datetime] so we check for lowercase alpha after bracket)
      expect { logger.info('hello') }.not_to output(/\[[a-z].*?\].*?hello/).to_stdout_from_any_process
    end
  end

  describe 'async writer integration' do
    after { Legion::Logging.stop_async_writer if Legion::Logging.async? }

    it 'does not start async writer on setup with async: false' do
      Legion::Logging.setup(level: 'info', async: false)
      expect(Legion::Logging.async?).to be false
    end

    it 'starts async writer when async: true' do
      Legion::Logging.setup(level: 'info', async: true)
      expect(Legion::Logging.async?).to be true
    end

    it 'defaults async to true' do
      Legion::Logging.setup(level: 'info')
      expect(Legion::Logging.async?).to be true
    end
  end
end
