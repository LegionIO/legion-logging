# legion-logging: Logging Framework for LegionIO

**Repository Level 3 Documentation**
- **Parent**: `/Users/miverso2/rubymine/legion/CLAUDE.md`

## Purpose

Ruby logging class for the LegionIO framework. Provides colorized console output via Rainbow, structured JSON logging (`format: :json`), and a consistent logging interface across all Legion gems and extensions.

**GitHub**: https://github.com/LegionIO/legion-logging
**Version**: 1.3.2
**License**: Apache-2.0

## Architecture

```
Legion::Logging (singleton module)
├── Methods         # Log level methods: debug, info, warn, error, fatal, unknown
├── Builder         # Output destination (stdout/file), log level, formatter, async: keyword
├── AsyncWriter     # Non-blocking SizedQueue-backed writer thread; fatal calls bypass queue
├── Hooks           # Callback registry for fatal/error/warn events (on_fatal, on_error, on_warn)
├── EventBuilder    # Structured event payload builder (caller, exception, lex, gem metadata)
├── Helper          # Injectable log mixin for LEX extensions (derives logger tags from segments/class)
├── Logger          # Core logger configuration and setup
├── MultiIO         # Write to multiple destinations simultaneously
├── SIEMExporter    # PHI-redacting SIEM export (Splunk HEC, ELK/OpenSearch)
├── Shipper         # Buffered log event forwarding (file/http transports)
├── Redactor        # PII/PHI pattern redaction
└── Version         # VERSION constant
```

### Key Design Patterns

- **Singleton Module**: `Legion::Logging` uses `class << self` - called directly: `Legion::Logging.info("msg")`
- **Rainbow Colorization**: Console output uses Rainbow gem for colored terminal output
- **Setup Method**: `Legion::Logging.setup(log_file:, level:, async: true)` configures output destination, level, and async mode
- **Async by Default**: `setup` enables async logging — calls return immediately. Fatal calls always bypass the queue. `stop_async_writer` flushes and stops on shutdown. Buffer size configurable via `Legion::Settings.dig(:logging, :async, :buffer_size)` (default 10,000). Back-pressure: callers block when buffer is full.
- **Structured JSON**: `format: :json` in settings outputs machine-parseable JSON log lines
- **Shared Interface**: Same method signature (`info`, `warn`, `error`, etc.) across all Legion components
- **MultiIO**: Splits writes to stdout and a log file simultaneously (used by Builder when `log_file` is set)
- **SIEMExporter**: PHI redaction (SSN, phone, MRN, DOB patterns), `export_to_splunk` (HEC), `format_for_elk`
- **Hook Callbacks**: `on_fatal`, `on_error`, `on_warn` register procs called after each log at those levels. Hooks are gated by `enable_hooks!`/`disable_hooks!`. Hook failures are silently rescued — never impact the logger. Hooks fire on the async writer thread; event context captured on caller thread.
- **EventBuilder**: Builds structured event hashes from log context (caller location, exception info, lex identity, gem metadata). All from in-memory data, zero IO.
- **Helper mixin**: `Legion::Logging::Helper` is injectable into LEX extensions. Derives logger tags from `segments`, `lex_filename`, or class name. Passes through `settings[:logger]` config when available.

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
| `lib/legion/logging/event_builder.rb` | Structured event payload builder |
| `lib/legion/logging/version.rb` | VERSION constant |

## Role in LegionIO

**Foundational gem** - used by `legion-cache`, `legion-data`, and `LegionIO` as a direct dependency. First module initialized during `Legion::Service` startup.

---

**Maintained By**: Matthew Iverson (@Esity)
