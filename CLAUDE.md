# legion-logging

Structured logging framework for LegionIO. Provides colorized console output (Rainbow), structured JSON logging, and a consistent interface across all Legion gems and extensions.

**GitHub**: https://github.com/LegionIO/legion-logging
**Version**: 1.5.3

## Architecture

```
Legion::Logging (singleton module)
├── Methods           # debug, info, warn, error, fatal, unknown; log_exception
├── Builder           # Output destination, log level, formatter, async: keyword
├── AsyncWriter       # Non-blocking SizedQueue-backed writer thread
├── Hooks             # Callback registry for fatal/error/warn events
├── EventBuilder      # Structured event payload + fingerprint for dedup
├── Helper            # Injectable log mixin for LEX extensions
├── TaggedLogger      # Prepends structured tags to each message
├── CategoryRegistry  # Named log categories with expected_fields
├── SIEMExporter      # PHI-redacting SIEM export (Splunk HEC, ELK)
├── Shipper           # Buffered forwarding (FileTransport, HttpTransport)
├── Redactor          # PII/PHI + secret pattern redaction (opt-in)
└── MultiIO           # Write to multiple destinations simultaneously

# Module-level writer lambdas (pluggable forwarding slots)
Legion::Logging.log_writer       # ->(event, routing_key:) {}
Legion::Logging.exception_writer # ->(event, routing_key:, headers:, properties:) {}
```

## Key Patterns

- **Singleton module** — `class << self`; called directly: `Legion::Logging.info("msg")`
- **Async by default** — `setup` enables async logging; fatal bypasses queue. Buffer size via `Settings[:logging][:async][:buffer_size]` (default 10,000). Back-pressure blocks callers when full.
- **Structured JSON** — `format: :json` outputs machine-parseable JSON lines (disables color)
- **Helper mixin** — `Legion::Logging::Helper` injects into LEX extensions; derives tags from `segments`, `lex_filename`, or class name
- **Writer lambdas** — `log_writer` and `exception_writer` are module-level lambda slots for forwarding to external systems (AMQP, etc.). Default no-ops.
- **Redactor** — Opt-in (`logging.redaction.enabled: true`). Patterns: SSN, phone, MRN, DOB, Vault tokens, JWTs, bearer tokens, lease IDs. Guards against Settings recursive init.
- **Hook callbacks** — `on_fatal`, `on_error`, `on_warn` register procs; gated by `enable_hooks!`/`disable_hooks!`; fire on async writer thread
- **EventBuilder** — Structured event hashes from log context (caller, exception, lex identity). `fingerprint` produces MD5 for dedup.

## Role in LegionIO

Foundational gem — dependency of `legion-cache`, `legion-data`, and `LegionIO`. First module initialized during `Legion::Service` startup.

---
**Maintained By**: Matthew Iverson (@Esity)
