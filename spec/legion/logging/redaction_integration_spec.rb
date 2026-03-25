# frozen_string_literal: true

require 'spec_helper'
require 'legion/logging/redactor'

RSpec.describe 'Legion::Logging redaction integration' do
  before do
    Legion::Logging.setup(level: 'debug', async: false, color: false)
    allow(Legion::Logging::Redactor).to receive(:redact_string).and_call_original
  end

  after do
    # Reset stub between examples
    Legion::Logging.setup(level: 'info', async: false, color: false)
  end

  context 'when logging.redaction.enabled is true' do
    before do
      stub_const('Legion::Settings', Module.new)
      allow(Legion::Settings).to receive(:dig).and_return(nil)
      allow(Legion::Settings).to receive(:dig).with(:logging, :redaction, :enabled).and_return(true)
    end

    it 'passes string messages through Redactor.redact_string on info' do
      Legion::Logging.info('call me at 612-555-1234')
      expect(Legion::Logging::Redactor).to have_received(:redact_string).at_least(:once)
    end

    it 'passes string messages through Redactor.redact_string on warn' do
      Legion::Logging.warn('SSN is 123-45-6789')
      expect(Legion::Logging::Redactor).to have_received(:redact_string).at_least(:once)
    end

    it 'passes string messages through Redactor.redact_string on error' do
      Legion::Logging.error('SSN is 123-45-6789')
      expect(Legion::Logging::Redactor).to have_received(:redact_string).at_least(:once)
    end

    it 'passes string messages through Redactor.redact_string on debug' do
      Legion::Logging.debug('SSN is 123-45-6789')
      expect(Legion::Logging::Redactor).to have_received(:redact_string).at_least(:once)
    end

    it 'passes string messages through Redactor.redact_string on fatal' do
      Legion::Logging.fatal('SSN is 123-45-6789')
      expect(Legion::Logging::Redactor).to have_received(:redact_string).at_least(:once)
    end
  end

  context 'when logging.redaction.enabled is false' do
    before do
      stub_const('Legion::Settings', Module.new)
      allow(Legion::Settings).to receive(:dig).and_return(nil)
      allow(Legion::Settings).to receive(:dig).with(:logging, :redaction, :enabled).and_return(false)
    end

    it 'does not call Redactor.redact_string' do
      Legion::Logging.info('call me at 612-555-1234')
      expect(Legion::Logging::Redactor).not_to have_received(:redact_string)
    end
  end

  context 'when Legion::Settings is not defined' do
    before do
      hide_const('Legion::Settings')
    end

    it 'does not raise and does not redact' do
      expect { Legion::Logging.info('test 123-45-6789') }.not_to raise_error
      expect(Legion::Logging::Redactor).not_to have_received(:redact_string)
    end
  end
end
