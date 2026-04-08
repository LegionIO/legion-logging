# legion-logging: Logging Framework for LegionIO

**Repository Level 3 Documentation**
- **Parent**: `/Users/miverso2/rubymine/legion/CLAUDE.md`

## Purpose

Ruby logging class for the LegionIO framework. Provides colorized console output via Rainbow, structured JSON logging (`format: :json`), and a consistent logging interface across all Legion gems and extensions.

**GitHub**: https://github.com/LegionIO/legion-logging
**Version**: 1.5.0
**License**: Apache-2.0

## Architecture

```
Legion::Logging (singleton module)
├── Methods           # Log level methods: debug, info, warn, error, fatal, unknown; log_exception helper
├── Builder           # Output destination (stdout/file), log level, formatter, async: keyword
├── AsyncWriter       # Non-blocking SizedQueue-backed writer thread; fatal calls bypass queue
├── Hooks             # Callback registry for fatal/error/warn events (on_fatal, on_error, on_warn)
├── EventBuilder      # Structured event payload builder (caller, exception, lex, gem metadata); fingerprint for dedup
├── Helper            # Injectable log mixin for LEX extensions (derives logger tags from segments/class)
├── Logger            # Core logger configuration and setup
├── MultiIO           # Write to multiple destinations simultaneously
├── TaggedLogger      # Logger wrapper that prepends structured tags to each message
├── CategoryRegistry  # Registry of named log categories with description and expected_fields
├── MethodTracer      # Tracing module for instrumenting method calls (call/return, formatted args)
├── SIEMExporter      # PHI-redacting SIEM export (Splunk HEC, ELK/OpenSearch)
├── Shipper           # Buffered log event forwarding; sub-transports: FileTransport, HttpTransport
├── Redactor          # PII/PHI + secret pattern redaction; opt-in via logging.redaction.enabled
└── Version           # VERSION constant

# Module-level writers (pluggable lambda slots replacing old Hooks for AMQP forwarding)
Legion::Logging.log_writer       # -> lambda(->(event, routing_key:) {})
Legion::Logging.exception_writer # -> lambda(->(event, routing_key:, headers:, properties:) {})
```

### Key Design Patterns

- **Singleton Module**: `Legion::Logging` uses `class << self` — called directly: `Legion::Logging.info("msg")`
- **Rainbow Colorization**: Console output uses Rainbow gem for colored terminal output. Color auto-disabled in JSON format and when writing to a log file.
- **Setup Method**: `Legion::Logging.setup(level:, format:, async:, **options)` configures output, level, format, and async mode. Increments `configuration_generation` on each call.
- **Async by Default**: `setup` enables async logging — calls return immediately. Fatal calls always bypass the queue. `stop_async_writer` flushes and stops on shutdown. Buffer size configurable via `Legion::Settings[:logging][:async][:buffer_size]` (default 10,000). Back-pressure: callers block when buffer is full.
- **Structured JSON**: `format: :json` in settings outputs machine-parseable JSON log lines (disables color)
- **Shared Interface**: Same method signature (`info`, `warn`, `error`, etc.) across all Legion components
- **MultiIO**: Splits writes to stdout and a log file simultaneously (used by Builder when `log_file` is set)
- **SIEMExporter**: PHI redaction (SSN, phone, MRN, DOB patterns), `export_to_splunk` (HEC), `format_for_elk`
- **Hook Callbacks**: `on_fatal`, `on_error`, `on_warn` register procs called after each log at those levels. Hooks are gated by `enable_hooks!`/`disable_hooks!`. Hook failures are silently rescued. Hooks fire on the async writer thread; event context captured on caller thread.
- **EventBuilder**: Builds structured event hashes from log context (caller location, exception info, lex identity, gem metadata). All from in-memory data, zero IO. `fingerprint` produces MD5 for dedup in log aggregation.
- **Helper mixin**: `Legion::Logging::Helper` is injectable into LEX extensions. Derives logger tags from `segments`, `lex_filename`, or class name. Passes through `settings[:logger]` config when available.
- **Writer Lambdas**: `log_writer` and `exception_writer` are module-level lambda slots for forwarding to external systems (AMQP, etc.). Default implementations are no-ops. Set via `Legion::Logging.log_writer = lambda`.
- **CategoryRegistry**: Named log categories with description and expected_fields. Register via `Legion::Logging.register_category`. Used for structured log validation.
- **Redactor**: Opt-in PII/PHI redaction (`logging.redaction.enabled: true`). Guards against Settings recursive init via `@loader` ivar check. Patterns: SSN, phone, MRN, DOB, Vault tokens, JWTs, bearer tokens, lease IDs.

## Dependencies

| Gem | Purpose |
|-----|---------|
| `rainbow` (~> 3) | Terminal colorization |

## File Map

| Path | Purpose |
|------|---------|
| `lib/legion/logging.rb` | Module entry point |
| `lib/legion/logging/methods.rb` | Log level methods |
| `lib/legion/logging/builder.rb` | Output config and formatter (async: keyword) |
| `lib/legion/logging/async_writer.rb` | Non-blocking SizedQueue-backed writer thread with back-pressure |
| `lib/legion/logging/helper.rb` | Injectable log mixin for LEX extensions |
| `lib/legion/logging/logger.rb` | Core logger setup |
| `lib/legion/logging/multi_io.rb` | Multi-output IO (write to multiple destinations simultaneously) |
| `lib/legion/logging/siem_exporter.rb` | PHI-redacting SIEM export helpers (Splunk HEC, ELK format) |
| `lib/legion/logging/hooks.rb` | Callback registry (fatal/error/warn hook arrays, enable/disable/clear) |
| `lib/legion/logging/event_builder.rb` | Structured event payload builder; `fingerprint` for MD5 dedup |
| `lib/legion/logging/tagged_logger.rb` | Logger wrapper that prepends structured tags to each message |
| `lib/legion/logging/category_registry.rb` | Named log category registration and lookup |
| `lib/legion/logging/method_tracer.rb` | Method call tracing instrumentation (call/return, formatted args) |
| `lib/legion/logging/shipper.rb` | Buffered log event forwarding to external systems |
| `lib/legion/logging/shipper/file_transport.rb` | File-based log shipper transport |
| `lib/legion/logging/shipper/http_transport.rb` | HTTP-based log shipper transport |
| `lib/legion/logging/siem_exporter.rb` | PHI-redacting SIEM export (Splunk HEC, ELK format) |
| `lib/legion/logging/redactor.rb` | PII/PHI + secret pattern redaction (opt-in) |
| `lib/legion/logging/version.rb` | VERSION constant |

## Role in LegionIO

**Foundational gem** - used by `legion-cache`, `legion-data`, and `LegionIO` as a direct dependency. First module initialized during `Legion::Service` startup.

---

**Maintained By**: Matthew Iverson (@Esity)
