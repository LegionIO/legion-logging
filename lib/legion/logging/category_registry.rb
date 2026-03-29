# frozen_string_literal: true

module Legion
  module Logging
    module CategoryRegistry
      VALID_NAME_PATTERN = /\A[a-z][a-z0-9]*(\.[a-z][a-z0-9]*)*\z/

      class << self
        def register_category(name, description: nil, expected_fields: [])
          name = name.to_s
          raise ArgumentError, "invalid category name: #{name.inspect}" unless name.match?(VALID_NAME_PATTERN)

          registry[name] = {
            name:            name,
            description:     description,
            expected_fields: Array(expected_fields)
          }.freeze
          name
        end

        def registered_categories
          registry.dup.freeze
        end

        def category_registered?(name)
          registry.key?(name.to_s)
        end

        def category_info(name)
          registry[name.to_s]
        end

        def clear!
          registry.clear
        end

        private

        def registry
          @registry ||= {}
        end
      end
    end
  end
end
