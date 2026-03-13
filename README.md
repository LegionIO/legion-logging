# legion-logging

Logging module for the [LegionIO](https://github.com/LegionIO/LegionIO) framework. Provides colorized console output via Rainbow and a consistent logging interface across all Legion gems and extensions.

## Installation

```bash
gem install legion-logging
```

Or add to your Gemfile:

```ruby
gem 'legion-logging'
```

## Usage

```ruby
require 'legion/logging'

Legion::Logging.setup(log_file: './legion.log', level: 'debug')
Legion::Logging.setup(level: 'info')  # defaults to stdout when no log_file specified

Legion::Logging.debug('debugging info')
Legion::Logging.info('hello')
Legion::Logging.warn('warning a user')
Legion::Logging.error('something went wrong')
Legion::Logging.fatal('critical failure')
```

### Structured JSON Output

Pass `format: :json` to disable colorization and emit machine-parseable JSON log lines:

```ruby
Legion::Logging.setup(level: 'info', format: :json)
```

This is useful for log aggregation pipelines (Elasticsearch, Splunk, etc.).

## Requirements

- Ruby >= 3.4

## License

Apache-2.0
