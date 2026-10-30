# legion-logging

Logging module for the [LegionIO](https://github.com/LegionIO/LegionIO) framework. Provides colorized console output via Rainbow, structured JSON logging, multi-output IO, and a consistent logging interface across all Legion gems and extensions.

**Version**: 1.5.20

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

### Log Rotation

File output rotates by size: the default is **100 MiB per file with five archives**
(`legion.log`, `legion.log.1` through `legion.log.5`). This covers `log_file:` and eligible
stdout/stderr files inherited from launchd, systemd `append:`, or shell `>>` redirects.
Only append-mode regular files are eligible; pipes, terminals, and non-append redirects (`>`)
are left unchanged. Stderr is checked independently, even when stdout is a pipe or below its limit.

Checks run during logger writes, at most once per second. **Raw stdout/stderr traffic alone does
not trigger a check**, and a burst or large write can exceed the size threshold. Archive retention
is not a hard disk-space cap. After rotation, raw writes follow the reopened descriptors.

Rotation runs on the logging worker in async mode. Direct rotation devices and explicit
synchronous logging still perform filesystem IO on their caller. External renames are detected
on the next eligible check and reopen the remembered original path. Paths are captured when
the shared stdio rotator is created; later application-level stream reassignment is not tracked.
Writes are serialized within each device, with one shared stdio rotator per process—not a lock
coordinating independent processes or separate file devices.

```json
{
  "logging": {
    "rotation": { "enabled": true, "max_size_mb": 100, "max_files": 5, "stdio": true }
  }
}
```

```ruby
Legion::Logging.setup(log_file: './legion.log', rotation: { max_size_mb: 50, max_files: 3 })
Legion::Logging.setup(log_file: './legion.log', rotation: false) # disable
Legion::Logging.setup(rotation: { stdio: false }) # leave inherited stdout/stderr alone
logger = Legion::Logging::Logger.new(log_file: './extension.log', rotation: { max_size_mb: 25 })
```

Omitting `rotation:` reads `logging.rotation` from already-loaded Settings, otherwise uses the
defaults above. Instance loggers honor the same overrides, including `rotation: false`.

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

Use `Legion::Logging.stop_async_writer(timeout: 2)` during shutdown. It closes admission and asks the worker to drain accepted entries, returning `true` only after that worker exits. A deadline expiry returns `false` without killing the worker or draining on the caller; release the blocked destination and retry shutdown. Calling shutdown from a writer callback requests closure but returns `false` rather than joining itself.

A successful stop means queued entries have been processed, not that a sink durably stored them or an external service acknowledged them. AsyncWriter reports sink/callback failures locally and does not automatically retry them. The Shipper's retained-batch retry behavior is separate.

Stopped async loggers reject new writes until explicitly restarted or configured with `setup(async: false)`. Reconfiguration stops the previous worker before replacing its output. `setup(shutdown_timeout: 2, ...)` returns `false` if that drain times out and does not change the existing output; it does not silently enter synchronous mode.

Lifecycle transitions are serialized per logger. A competing setup/start/stop returns `false` instead of creating overlapping workers or blocking a callback behind its own shutdown. Retry the control operation after the active transition completes.

Configuration is a synchronous control path: opening or closing owned log files can still block in `setup`. Shutdown deadlines bound worker drain/join, not every filesystem operation.

Producers evaluate message blocks and capture caller/context plus shallow snapshots of strings, arrays, hashes, and exceptions. The worker performs formatting, redaction, structured-event enrichment, fingerprinting, and envelope construction. Nested payload objects are not deep-copied. Explicit caller tracing and application-provided message/settings methods can still perform producer-side work.

Text and JSON timestamps represent enqueue time, not time spent waiting for a destination. JSON thread IDs identify the producer. Standard Logger calls use the same shallow snapshot policy for messages and context; custom raw Logger formatters receive the producer timestamp. The worker preserves producer-side `with_level` admission and already-resolved message/progname values, including a block's nil result.

Forwarding defaults to warn/error/fatal. Set `logging.transport.log_levels` to an array of strings or symbols to change which locally emitted levels reach `log_writer` and Hooks; absent or empty lists retain the defaults. Library-owned Settings lookups use defaults while Settings is unloaded rather than triggering initialization.

The standard Ruby Logger interface returned by `Legion::Logging.log` also queues output in async mode, including `add`, `log`, and `<<`. Instance tracing uses the same async path. If an async writer is unavailable or rejects an entry during shutdown, logging raises `ClosedQueueError` rather than falling back to synchronous IO. Explicit synchronous mode retains direct output.

Logs generated by a writer callback or hook are written locally on that worker rather than queued behind themselves or forwarded recursively. Nested exception events and recursive formatter diagnostics use local JSON lines. This keeps bounded backpressure for producers without allowing the sole consumer to deadlock on its own queue.

### Structured JSON Output

Pass `format: :json` to disable colorization and emit machine-parseable JSON log lines:

```ruby
Legion::Logging.setup(level: 'info', format: :json)
```

This is useful for log aggregation pipelines (Elasticsearch, Splunk, etc.).

### Multi-Output IO

`Legion::Logging::MultiIO` writes to destinations sequentially—for example, stdout followed by a file. It is a synchronous IO primitive used by the async writer, not a parallel executor. A slow destination delays that worker and can eventually cause queue backpressure.

Opt-in `MethodTracer` output uses the configured logging queue rather than writing directly to the traced application's stdout. Hook dispatch is synchronous on its invoking thread; normal async logging invokes hooks on the writer, not on producers.

### Buffered Shipping

Explicitly require `legion/logging/shipper` and enable `logging.shipper.enabled` to use the file or HTTP batch shipper. `Shipper.ship(event)` starts its worker automatically and never performs threshold-triggered delivery on the producer. Filtering and redaction still run on the calling thread; batch delivery runs on the worker. Set `logging.shipper.transport` to `file` or `http`.

Defaults: `batch_size: 100`, `flush_interval: 5` seconds, and `buffer_size: 10_000`. The capacity includes in-flight events; producers wait when it is full. Failed batches remain queued in order for retry.

`Shipper.flush(timeout: 5)` requests worker delivery and waits up to the supplied deadline; it returns `false` on timeout or delivery failure. `Shipper.stop(timeout: 5)` wakes and joins the worker without moving delivery onto the caller. A timeout retains the worker and accepted events; check the return value before assuming delivery completed. If shutdown exits after a delivery failure, retrying `stop` starts a drainer for the retained batch.

`FileTransport.ship_batch` and `HttpTransport.ship_batch` are intentionally synchronous delivery primitives; use `Shipper.ship` for producer-side asynchronous shipping. Sink failures are reported locally to stderr instead of being forwarded back into the failing shipper.

### SIEM Export

`Legion::Logging::SIEMExporter` provides PHI-redacting export helpers for security event pipelines:

`export_to_splunk` is an explicitly synchronous request/response API. Use the HTTP Shipper for asynchronous delivery. Both HTTP implementations configure 5-second connection and 10-second read/write timeouts; these are phase timeouts, not a total request deadline.

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

`log_writer` and `exception_writer` are pluggable lambda slots for forwarding events to external systems. They coexist with Hooks; normal async logging invokes both on the writer thread:

```ruby
Legion::Logging.exception_writer = lambda do |payload, routing_key:, headers:, properties:|
  publish_to_amqp(payload, routing_key:, headers:, properties:)
end

Legion::Logging.log_writer = lambda do |context, routing_key:, headers:, properties:|
  publish_log(context, routing_key:, headers:, properties:)
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
