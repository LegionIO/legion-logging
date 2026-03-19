# legion-logging

Logging module for the [LegionIO](https://github.com/LegionIO/LegionIO) framework. Provides colorized console output via Rainbow, structured JSON logging, multi-output IO, and a consistent logging interface across all Legion gems and extensions.

**Version**: 1.2.5

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

### Multi-Output IO

`Legion::Logging::MultiIO` writes to multiple destinations simultaneously — for example, stdout and a file at the same time. Used internally by the Builder when `log_file` is set alongside console output.

### SIEM Export

`Legion::Logging::SIEMExporter` provides PHI-redacting export helpers for security event pipelines:

```ruby
# Redact PHI patterns (SSN, phone, MRN, DOB) from a string
clean = Legion::Logging::SIEMExporter.redact_phi(raw_message)

# Export to Splunk HEC
Legion::Logging::SIEMExporter.export_to_splunk(event, hec_url: url, token: token)

# Format for ELK/OpenSearch
Legion::Logging::SIEMExporter.format_for_elk(event, index: 'legion')
```

PHI patterns redacted: SSN (`###-##-####`), phone (`###-###-####`), MRN (`XX#######`), DOB (`##/##/####`).

## Requirements

- Ruby >= 3.4

## License

Apache-2.0
