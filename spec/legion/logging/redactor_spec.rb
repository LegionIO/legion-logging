# frozen_string_literal: true

require 'spec_helper'
require 'legion/logging/redactor'

RSpec.describe Legion::Logging::Redactor do
  describe '.redact_string' do
    it 'redacts SSN' do
      expect(described_class.redact_string('SSN is 123-45-6789 here')).to include('[REDACTED]')
      expect(described_class.redact_string('SSN is 123-45-6789 here')).not_to include('123-45-6789')
    end

    it 'redacts email addresses' do
      expect(described_class.redact_string('Email: user@example.com')).to include('[REDACTED]')
      expect(described_class.redact_string('Email: user@example.com')).not_to include('user@example.com')
    end

    it 'redacts US phone numbers' do
      expect(described_class.redact_string('Call 555-123-4567')).to include('[REDACTED]')
      expect(described_class.redact_string('Call (555) 123-4567')).to include('[REDACTED]')
    end

    it 'redacts MRN patterns' do
      expect(described_class.redact_string('MRN: 1234567')).to include('[REDACTED]')
      expect(described_class.redact_string('mrn:12345678')).to include('[REDACTED]')
    end

    it 'redacts DOB patterns' do
      expect(described_class.redact_string('DOB: 01/15/1990')).to include('[REDACTED]')
      expect(described_class.redact_string('dob: 1-15-90')).to include('[REDACTED]')
    end

    it 'redacts credit card numbers' do
      expect(described_class.redact_string('card 4111 1111 1111 1111')).to include('[REDACTED]')
      expect(described_class.redact_string('4111-1111-1111-1111')).to include('[REDACTED]')
    end

    it 'passes through clean text unchanged' do
      expect(described_class.redact_string('hello world')).to eq('hello world')
    end

    it 'returns a new string, not the original' do
      original = 'hello 123-45-6789'
      result   = described_class.redact_string(original)
      expect(result).not_to equal(original)
    end
  end

  describe '.redact' do
    it 'returns non-hash values unchanged' do
      expect(described_class.redact('plain string')).to eq('plain string')
      expect(described_class.redact(42)).to eq(42)
      expect(described_class.redact(nil)).to be_nil
    end

    it 'redacts string values in a flat hash' do
      event  = { message: 'SSN 123-45-6789 found', level: 'error' }
      result = described_class.redact(event)
      expect(result[:message]).to include('[REDACTED]')
      expect(result[:level]).to eq('error')
    end

    it 'redacts string values in nested hashes' do
      event  = { outer: { inner: 'email user@example.com here' } }
      result = described_class.redact(event)
      expect(result[:outer][:inner]).to include('[REDACTED]')
    end

    it 'redacts string values inside arrays' do
      event  = { tags: ['SSN 123-45-6789', 'clean tag'] }
      result = described_class.redact(event)
      expect(result[:tags][0]).to include('[REDACTED]')
      expect(result[:tags][1]).to eq('clean tag')
    end

    it 'recursively handles arrays of hashes' do
      event  = { items: [{ note: 'DOB: 01/01/2000' }] }
      result = described_class.redact(event)
      expect(result[:items][0][:note]).to include('[REDACTED]')
    end

    it 'passes through non-string, non-hash, non-array values' do
      event  = { count: 42, active: true, ratio: 3.14 }
      result = described_class.redact(event)
      expect(result[:count]).to eq(42)
      expect(result[:active]).to be(true)
      expect(result[:ratio]).to be_within(0.001).of(3.14)
    end
  end

  describe 'sensitive field redaction' do
    it 'redacts the entire value for fields named password' do
      event  = { password: 'super-secret-password-123' }
      result = described_class.redact(event)
      expect(result[:password]).to eq('[REDACTED]')
    end

    it 'redacts the entire value for fields named secret' do
      event  = { secret: 'my-secret-value' }
      result = described_class.redact(event)
      expect(result[:secret]).to eq('[REDACTED]')
    end

    it 'redacts the entire value for fields named token' do
      event  = { token: 'eyJhbGciOiJIUzI1NiJ9.payload.sig' }
      result = described_class.redact(event)
      expect(result[:token]).to eq('[REDACTED]')
    end

    it 'redacts the entire value for fields named api_key' do
      event  = { api_key: 'sk-abc123xyz' }
      result = described_class.redact(event)
      expect(result[:api_key]).to eq('[REDACTED]')
    end

    it 'redacts the entire value for fields named authorization' do
      event  = { authorization: 'Bearer some-token-here' }
      result = described_class.redact(event)
      expect(result[:authorization]).to eq('[REDACTED]')
    end

    it 'treats string keys the same as symbol keys for sensitive fields' do
      event  = { 'password' => 'my-password' }
      result = described_class.redact(event)
      expect(result['password']).to eq('[REDACTED]')
    end
  end

  describe 'custom patterns' do
    before { described_class.send(:reset_pattern_cache!) }
    after  { described_class.send(:reset_pattern_cache!) }

    it 'applies custom patterns from Legion::Settings when available' do
      stub_const('Legion::Settings', Module.new)
      allow(Legion::Settings).to receive(:[]).and_return(nil)
      allow(Legion::Settings).to receive(:[]).with(:logging, :redactor, :custom_patterns)
                                             .and_return({ 'member_id' => '\bU\d{9}\b' })

      result = described_class.redact_string('member U123456789 enrolled')
      expect(result).to include('[REDACTED]')
      expect(result).not_to include('U123456789')
    end

    it 'skips invalid regex patterns gracefully' do
      stub_const('Legion::Settings', Module.new)
      allow(Legion::Settings).to receive(:[]).and_return(nil)
      allow(Legion::Settings).to receive(:[]).with(:logging, :redactor, :custom_patterns)
                                             .and_return({ 'bad' => '[invalid(' })

      expect { described_class.redact_string('hello') }.not_to raise_error
    end

    it 'returns empty hash when Legion::Settings is not defined' do
      expect(described_class.send(:custom_patterns)).to eq({})
    end
  end

  describe 'REDACTED constant' do
    it 'is the expected replacement string' do
      expect(described_class::REDACTED).to eq('[REDACTED]')
    end
  end
end
