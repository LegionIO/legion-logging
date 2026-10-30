# legion-logging

Structured logging framework for LegionIO. Provides colorized console output (Rainbow), structured JSON logging, and a consistent interface across all Legion gems and extensions.

## Architecture

```
Legion::Logging (singleton module)
├── Methods           # debug, info, warn, error, fatal, unknown; log_exception
├── Builder           # Output destination, log level, formatter, async: keyword
├── AsyncWriter       # Bounded, backpressured SizedQueue-backed writer thread
├── OutputLogger      # Queues standard Logger add/log/<< calls
├── Hooks             # Callback registry for fatal/error/warn events
├── EventBuilder      # Structured event payload + fingerprint for dedup
├── Helper            # Injectable log mixin for LEX extensions
├── TaggedLogger      # Prepends structured tags to each message
├── CategoryRegistry  # Named log categories with expected_fields
├── SIEMExporter      # PHI-redacting SIEM export (Splunk HEC, ELK)
├── Shipper           # Bounded batch-delivery worker (file/HTTP transports)
├── Redactor          # PII/PHI + secret pattern redaction (opt-in)
├── MultiIO           # Synchronous, sequential writes to multiple destinations
└── Rotation          # RotatingFile (log_file) + shared StdioRotator (redirected stdout/stderr)

# Module-level writer lambdas (pluggable forwarding slots)
Legion::Logging.log_writer       # ->(event, routing_key:, headers:, properties:) {}
Legion::Logging.exception_writer # ->(event, routing_key:, headers:, properties:) {}
```

## Key Patterns

- **Singleton module** — `class << self`; called directly: `Legion::Logging.info("msg")`
- **Async by default** — `setup` queues all levels, including fatal, plus structured exception publication and raw Logger calls. Buffer size via `Settings[:logging][:async][:buffer_size]` (default 10,000 entries, not bytes). Saturation blocks producers rather than dropping logs or growing the queue without bound.
- **Structured JSON** — `format: :json` outputs machine-parseable JSON lines (disables color)
- **Producer/worker boundary** — Producers evaluate message blocks and capture caller/context plus shallow snapshots. Formatting, event enrichment, fingerprinting, and publication run on the worker. Nested payload objects are not deep-copied. Built-in output retains producer time/thread; raw Logger output retains admission, normalized payload, and formatter time.
- **Lifecycle** — `stop_async_writer(timeout: 2)` closes admission and drains on the worker; timeout or lifecycle contention returns false. No caller-thread drain or synchronous rejection fallback. Stopped async loggers raise `ClosedQueueError` until restart or explicit `setup(async: false)`. Setup file operations remain synchronous.
- **Delivery semantics** — Successful shutdown means processing finished, not durable delivery or external acknowledgement. AsyncWriter diagnoses failures locally without retry; Shipper retains failed batches for retry.
- **Helper mixin** — `Legion::Logging::Helper` injects into LEX extensions; derives tags from `segments`, `lex_filename`, or class name
- **Writer lambdas** — `log_writer` and `exception_writer` are module-level lambda slots for forwarding to external systems (AMQP, etc.). Default no-ops.
- **Redactor** — Opt-in (`logging.redaction.enabled: true`). Patterns: SSN, phone, MRN, DOB, Vault tokens, JWTs, bearer tokens, lease IDs. Guards against Settings recursive init.
- **Hook callbacks** — `on_fatal`, `on_error`, `on_warn` register procs; gated by `enable_hooks!`/`disable_hooks!`; fire on async writer thread
- **Reentrant logging** — Callback/hook logs stay local on the worker without recursively forwarding or waiting on its own queue. Nested exception events and recursive formatter diagnostics use local JSON lines.
- **Forwarding levels** — `logging.transport.log_levels` accepts strings/symbols; absent or empty lists default to warn/error/fatal. Settings guards use defaults while Settings is unloaded rather than initializing it.
- **Synchronous APIs** — `MultiIO`, direct transport delivery, SIEM export, and direct hook dispatch remain synchronous. Shipper filtering/redaction run on its caller; bounded batch delivery runs on its worker.
- **EventBuilder** — Structured event hashes from log context (caller, exception, lex identity). `fingerprint` produces MD5 for dedup.
- **Rotation** — Hard managed-content cap: 100 MiB per file plus five archives (600 MiB/path). `RotatingFile` splits writes, trims oversized existing files, prunes excess archives, and coordinates same-path/same-policy writers through a persistent zero-byte `.lock`. Regular data FDs close between operations. Eligible append-mode inherited stdout/stderr become bounded pipes drained by dedicated capped sinks, including raw-only and child writes; saturation blocks, errors fail closed. `stop_async_writer` drains both layers under one deadline, including sync/file-only module logging; call it after final raw writes. Capture is process-wide; disable only with quiescent producers. Pre-drain timeout keeps capture active; final cleanup failure/timeout requires restart. Instance loggers survive disable/re-enable. Forked children cannot control parent workers or change their policy. File contents are bounded, not filesystem metadata/snapshots, external writers/aliases, or externally held/inherited descriptors; a volume-level guarantee needs an OS quota.

## Role in LegionIO

Foundational gem — dependency of `legion-cache`, `legion-data`, and `LegionIO`. First module initialized during `Legion::Service` startup.

## Backtrace Limit

- `settings[:logging][:backtrace_limit]` — `nil` = full trace, `0` = suppress entirely, `N` = cap at N frames
- Per-call override: `log_exception(err, backtrace_limit: 5)`
- Read at runtime via `Legion::Settings.dig(:logging, :backtrace_limit)` after checking Settings is loaded; otherwise use the default without triggering initialization.

