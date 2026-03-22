# frozen_string_literal: true

require 'legion/logging'
require 'legion/logging/hooks'

RSpec.describe Legion::Logging::Hooks do
  after { Legion::Logging.clear_hooks! }

  describe '.on_fatal / .on_error / .on_warn' do
    it 'registers a fatal hook' do
      Legion::Logging.on_fatal { |_event| nil }
      expect(Legion::Logging::Hooks.hooks[:fatal].size).to eq(1)
    end

    it 'registers an error hook' do
      Legion::Logging.on_error { |_event| nil }
      expect(Legion::Logging::Hooks.hooks[:error].size).to eq(1)
    end

    it 'registers a warn hook' do
      Legion::Logging.on_warn { |_event| nil }
      expect(Legion::Logging::Hooks.hooks[:warn].size).to eq(1)
    end
  end

  describe '.enable_hooks! / .disable_hooks!' do
    it 'starts disabled' do
      expect(Legion::Logging::Hooks.enabled?).to be false
    end

    it 'can be enabled and disabled' do
      Legion::Logging.enable_hooks!
      expect(Legion::Logging::Hooks.enabled?).to be true
      Legion::Logging.disable_hooks!
      expect(Legion::Logging::Hooks.enabled?).to be false
    end
  end

  describe '.clear_hooks!' do
    it 'removes all registered hooks' do
      Legion::Logging.on_fatal { |_| nil }
      Legion::Logging.on_error { |_| nil }
      Legion::Logging.on_warn { |_| nil }
      Legion::Logging.clear_hooks!
      expect(Legion::Logging::Hooks.hooks.values.flatten).to be_empty
    end
  end
end
