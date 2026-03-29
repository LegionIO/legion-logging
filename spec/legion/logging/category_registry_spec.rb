# frozen_string_literal: true

require 'spec_helper'
require 'legion/logging/category_registry'

RSpec.describe Legion::Logging::CategoryRegistry do
  before { described_class.clear! }

  describe '.register_category' do
    it 'registers a simple category name' do
      described_class.register_category('security')
      expect(described_class.category_registered?('security')).to be true
    end

    it 'registers a hierarchical dot-separated name' do
      described_class.register_category('agent.execution')
      expect(described_class.category_registered?('agent.execution')).to be true
    end

    it 'registers a deeply nested name' do
      described_class.register_category('security.finding.critical')
      expect(described_class.category_registered?('security.finding.critical')).to be true
    end

    it 'stores description metadata' do
      described_class.register_category('audit.access', description: 'User access audit events')
      info = described_class.category_info('audit.access')
      expect(info[:description]).to eq('User access audit events')
    end

    it 'stores expected_fields metadata' do
      described_class.register_category('agent.execution', expected_fields: %w[agent_id duration_ms])
      info = described_class.category_info('agent.execution')
      expect(info[:expected_fields]).to eq(%w[agent_id duration_ms])
    end

    it 'returns the registered name' do
      result = described_class.register_category('task.complete')
      expect(result).to eq('task.complete')
    end

    it 'accepts a symbol name and coerces to string' do
      described_class.register_category(:'security.finding')
      expect(described_class.category_registered?('security.finding')).to be true
    end

    it 'raises ArgumentError for names with uppercase letters' do
      expect { described_class.register_category('Security') }.to raise_error(ArgumentError, /invalid category name/)
    end

    it 'raises ArgumentError for names starting with a digit' do
      expect { described_class.register_category('1security') }.to raise_error(ArgumentError, /invalid category name/)
    end

    it 'raises ArgumentError for names with spaces' do
      expect { described_class.register_category('security finding') }.to raise_error(ArgumentError, /invalid category name/)
    end

    it 'raises ArgumentError for empty name' do
      expect { described_class.register_category('') }.to raise_error(ArgumentError, /invalid category name/)
    end

    it 'overwrites an existing registration with new metadata' do
      described_class.register_category('infra.deploy', description: 'v1')
      described_class.register_category('infra.deploy', description: 'v2')
      expect(described_class.category_info('infra.deploy')[:description]).to eq('v2')
    end
  end

  describe '.registered_categories' do
    it 'returns an empty hash when nothing is registered' do
      expect(described_class.registered_categories).to eq({})
    end

    it 'returns all registered categories keyed by name' do
      described_class.register_category('net.connect')
      described_class.register_category('net.disconnect')
      categories = described_class.registered_categories
      expect(categories.keys).to contain_exactly('net.connect', 'net.disconnect')
    end

    it 'returns a frozen copy that cannot be mutated' do
      described_class.register_category('sys.boot')
      copy = described_class.registered_categories
      expect(copy).to be_frozen
    end

    it 'returned copy does not share identity with the internal registry' do
      described_class.register_category('sys.boot')
      copy = described_class.registered_categories
      expect(copy).not_to be(described_class.registered_categories.object_id)
    end
  end

  describe '.category_registered?' do
    it 'returns true for a registered category' do
      described_class.register_category('task.start')
      expect(described_class.category_registered?('task.start')).to be true
    end

    it 'returns false for an unknown category' do
      expect(described_class.category_registered?('does.not.exist')).to be false
    end

    it 'accepts a symbol argument' do
      described_class.register_category('task.start')
      expect(described_class.category_registered?(:'task.start')).to be true
    end
  end

  describe '.category_info' do
    it 'returns the metadata hash for a registered category' do
      described_class.register_category('audit.login', description: 'Login events', expected_fields: ['user_id'])
      info = described_class.category_info('audit.login')
      expect(info[:name]).to eq('audit.login')
      expect(info[:description]).to eq('Login events')
      expect(info[:expected_fields]).to eq(['user_id'])
    end

    it 'returns nil for an unregistered category' do
      expect(described_class.category_info('ghost')).to be_nil
    end
  end
end
