# frozen_string_literal: true

require_relative 'lib/legion/logging/version'

Gem::Specification.new do |spec|
  spec.name = 'legion-logging'
  spec.version       = Legion::Logging::VERSION
  spec.authors       = ['Esity']
  spec.email         = ['matthewdiverson@gmail.com']

  spec.summary       = 'The logging class that the LegionIO framework uses'
  spec.description   = 'A logging class used by the LegionIO framework'
  spec.homepage      = 'https://github.com/LegionIO/legion-logging'
  spec.license       = 'Apache-2.0'
  spec.require_paths = ['lib']
  spec.required_ruby_version = '>= 3.4'
  spec.files = `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  spec.extra_rdoc_files = %w[README.md LICENSE CHANGELOG.md]
  spec.metadata = {
    'bug_tracker_uri'       => 'https://github.com/LegionIO/legion-logging/issues',
    'changelog_uri'         => 'https://github.com/LegionIO/legion-logging/blob/main/CHANGELOG.md',
    'documentation_uri'     => 'https://github.com/LegionIO/legion-logging',
    'homepage_uri'          => 'https://github.com/LegionIO/LegionIO',
    'source_code_uri'       => 'https://github.com/LegionIO/legion-logging',
    'wiki_uri'              => 'https://github.com/LegionIO/legion-logging/wiki',
    'rubygems_mfa_required' => 'true'
  }

  spec.add_dependency 'logger'
  spec.add_dependency 'rainbow', '~> 3'
end
