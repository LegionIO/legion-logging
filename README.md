# legion-logging

Logging module for the [LegionIO](https://github.com/LegionIO/LegionIO) framework. Provides colorized console output via Rainbow, structured JSON logging, multi-output IO, and a consistent logging interface across all Legion gems and extensions.

**Version**: 1.5.9

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

### Async Logging

By default, `setup` enables async logging: log calls enqueue output for a background writer, including fatal messages. Async does not mean wait-free. The queue holds at most 10,000 entries by default, and producers wait for capacity when it fills.

```ruby
# Async is on by default
Legion::Logging.setup(level: 'info')

# Disable async (synchronous mode)
Legion::Logging.setup(level: 'info', async: false)

# Configure buffer size via Legion::Settings
# Legion::Settings[:logging][:async] = { buffer_size: 20_000 }
```

Bounded backpressure is intentional: saturation blocks callers rather than dropping logs or allowing unbounded memory growth. A stalled destination can therefore stall producers once the queue fills. Buffer capacity limits queued entries, not their total byte size, and does not guarantee delivery across process termination.

Use `Legion::Logging.stop_async_writer` during shutdown to flush and stop the writer thread; check its return value before assuming the flush completed.

The standard Ruby Logger interface returned by `Legion::Logging.log` also queues output in async mode, including `add`, `log`, and `<<`. Instance tracing uses the same async path. If an async writer is unavailable or rejects an entry during shutdown, logging raises `ClosedQueueError` rather than falling back to synchronous IO. Explicit synchronous mode retains direct output.

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

### Helper Mixin

`Legion::Logging::Helper` is an injectable mixin for LEX extensions. It derives logger tags from `segments`, `lex_filename`, or class name automatically, and passes through `settings[:logger]` config when available. Allows LEX gems to use `legion-logging` directly without requiring the full LegionIO framework.

```ruby
class MyRunner
  include Legion::Logging::Helper

  def run
    log.info("starting")
    log.debug("details")
  end
end
```

### Exception Logging

`log_exception` provides a single call for complete exception logging with component context. It writes a human-readable exception line and publishes a structured exception event when an `exception_writer` is configured. With async logging enabled, both output and exception publication run on the writer thread; Helper `handle_exception` uses the same publication path. Bounded queue backpressure still applies.

```ruby
begin
  runner.call
rescue StandardError => e
  Legion::Logging.log_exception(
    e,
    handled: true,
    component_type: :runner,
    lex: 'my_extension',
    task_id: 'abc-123'
  )
end
```

The human-readable log line includes the full Ruby backtrace unless `backtrace_limit` is configured. Legion does not replace the tail with `... N more`.

Structured exception events include:

- exception class and message
- full backtrace array
- caller file, line, and function where available
- log level and handled/unhandled status
- component type, lex name, gem name, version, and source path metadata
- task and thread context
- stable error fingerprint for deduplication

### Writer Lambdas

`log_writer` and `exception_writer` are pluggable lambda slots that replace the old Hooks system. Assign them to forward events to external systems:

```ruby
Legion::Logging.exception_writer = lambda do |payload, routing_key:, headers:, properties:|
  publish_to_amqp(payload, routing_key:, headers:, properties:)
end

Legion::Logging.log_writer = lambda do |context, routing_key:|
  publish_log(context, routing_key:)
end
```

### EventBuilder

`EventBuilder.build_exception` constructs rich structured exception payloads including caller location, lex identity, and gem metadata. `EventBuilder.fingerprint` produces an MD5 fingerprint of stable error fields for deduplication in log aggregation pipelines.

### Redactor

`Legion::Logging::Redactor` redacts PII/PHI patterns (SSN, email, phone, MRN, DOB, credit card) plus Vault tokens, JWTs, bearer tokens, `vault://` URIs, `lease://` URIs, and lease IDs from log messages. Redaction is opt-in for text log lines: load the module (for example via `require 'legion/logging/redactor'`) and enable it with `logging.redaction.enabled: true`. When loaded and enabled, it is wired into all log methods in the write path.

Structured exception events are redacted before publishing when the redactor is loaded. This includes event identity fields such as `user`, so email-shaped local usernames are not forwarded raw.

## Requirements

- Ruby >= 3.4

## License

Apache-2.0
