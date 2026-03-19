# legion-logging: Logging Framework for LegionIO

**Repository Level 3 Documentation**
- **Parent**: `/Users/miverso2/rubymine/legion/CLAUDE.md`

## Purpose

Ruby logging class for the LegionIO framework. Provides colorized console output via Rainbow, structured JSON logging (`format: :json`), and a consistent logging interface across all Legion gems and extensions.

**GitHub**: https://github.com/LegionIO/legion-logging
**Version**: 1.2.5
**License**: Apache-2.0

## Architecture

```
Legion::Logging (singleton module)
├── Methods         # Log level methods: debug, info, warn, error, fatal, unknown
├── Builder         # Output destination (stdout/file), log level, formatter
├── Logger          # Core logger configuration and setup
├── MultiIO         # Write to multiple destinations simultaneously
├── SIEMExporter    # PHI-redacting SIEM export (Splunk HEC, ELK/OpenSearch)
└── Version         # VERSION constant (1.2.5)
```

### Key Design Patterns

- **Singleton Module**: `Legion::Logging` uses `class << self` - called directly: `Legion::Logging.info("msg")`
- **Rainbow Colorization**: Console output uses Rainbow gem for colored terminal output
- **Setup Method**: `Legion::Logging.setup(log_file:, level:)` configures output destination and level
- **Structured JSON**: `format: :json` in settings outputs machine-parseable JSON log lines
- **Shared Interface**: Same method signature (`info`, `warn`, `error`, etc.) across all Legion components
- **MultiIO**: Splits writes to stdout and a log file simultaneously (used by Builder when `log_file` is set)
- **SIEMExporter**: PHI redaction (SSN, phone, MRN, DOB patterns), `export_to_splunk` (HEC), `format_for_elk`

## Dependencies

| Gem | Purpose |
|-----|---------|
| `rainbow` (~> 3) | Terminal colorization |

## File Map

| Path | Purpose |
|------|---------|
| `lib/legion/logging.rb` | Module entry point |
| `lib/legion/logging/methods.rb` | Log level methods |
| `lib/legion/logging/builder.rb` | Output config and formatter |
| `lib/legion/logging/logger.rb` | Core logger setup |
| `lib/legion/logging/multi_io.rb` | Multi-output IO (write to multiple destinations simultaneously) |
| `lib/legion/logging/siem_exporter.rb` | PHI-redacting SIEM export helpers (Splunk HEC, ELK format) |
| `lib/legion/logging/version.rb` | VERSION constant |

## Role in LegionIO

**Foundational gem** - used by `legion-cache`, `legion-data`, and `LegionIO` as a direct dependency. First module initialized during `Legion::Service` startup.

---

**Maintained By**: Matthew Iverson (@Esity)
