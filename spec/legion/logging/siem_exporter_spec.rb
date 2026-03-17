# frozen_string_literal: true

require 'spec_helper'
require 'legion/logging/siem_exporter'

RSpec.describe Legion::Logging::SIEMExporter do
  describe '.redact_phi' do
    it 'redacts SSN' do
      expect(described_class.redact_phi('SSN: 123-45-6789')).to include('[SSN-REDACTED]')
    end

    it 'redacts phone' do
      expect(described_class.redact_phi('Call 555-123-4567')).to include('[PHONE-REDACTED]')
    end

    it 'redacts MRN' do
      expect(described_class.redact_phi('MRN: AB1234567')).to include('[MRN-REDACTED]')
    end

    it 'passes clean text through' do
      expect(described_class.redact_phi('hello world')).to eq('hello world')
    end
  end

  describe '.format_for_elk' do
    it 'produces elk-compatible hash' do
      result = described_class.format_for_elk('test event')
      expect(result).to have_key('@timestamp')
      expect(result['message']).to eq('test event')
      expect(result['source']).to eq('legion')
    end

    it 'accepts custom index' do
      result = described_class.format_for_elk('test', index: 'custom')
      expect(result['index']).to eq('custom')
    end
  end
end
