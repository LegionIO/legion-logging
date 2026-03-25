# Legion::Logging Changelog

## [1.3.5] - 2026-03-24

### Added
- Automatic PII/PHI redaction in log write path: all log methods (`debug`, `info`, `warn`, `error`, `fatal`, `unknown`) pass string messages through `Legion::Logging::Redactor.redact_string` when `logging.redaction.enabled` is `true` (default: `false`)
- `maybe_redact(message)` private helper on `Legion::Logging::Methods` — no-ops when redaction is disabled, `Redactor` is not defined, or message is not a string
- Hook callbacks (`on_warn`, `on_error`, `on_fatal`) receive already-redacted message so no PHI leaks through hook dispatch

### Fixed
- `redaction_enabled?` guards against recursive `Legion::Settings::Loader` initialization by checking `@loader` ivar directly before calling `dig`; prevents infinite recursion when settings bootstrap calls `Legion::Logging.warn`

## [1.3.4] - 2026-03-24

### Fixed
- `EventBuilder#derive_lex_source` no longer blindly prepends `lex-` to all source names (was causing `add_gem_info` to fail for core gems like `legion-data` with `Could not find 'lex-data'`)
- `EventBuilder#add_gem_info` now tries raw name, `lex-<name>`, and `legion-<name>` prefixes when resolving gem specs (extracted to `resolve_gem_spec` method)

## [1.3.3] - 2026-03-24

### Changed
- Reindex docs: update CLAUDE.md and README with AsyncWriter and Helper module docs

## [1.3.2] - 2026-03-22

### Added
- `Legion::Logging::Helper` module: injectable `log` mixin for LEX extensions
- Derives logger tags from `segments`, `lex_filename`, or class name (in priority order)
- Passes through `settings[:logger]` config when available
- Allows LEX gems to use `legion-logging` directly instead of requiring the full LegionIO framework

## [1.3.1] - 2026-03-22

### Fixed
- Replace `Legion::Settings[:logging, :shipper, ...]` multi-arg bracket calls with `Legion::Settings.dig(...)` — `Settings#[]` only accepts 1 argument, causing `ArgumentError: wrong number of arguments (given 3, expected 1)` on boot
- Affected: `logging.rb` (async buffer_size), `shipper.rb` (5 calls), `redactor.rb`, `file_transport.rb`, `http_transport.rb` (2 calls)

## [1.3.0] - 2026-03-22

### Added
- `Legion::Logging::AsyncWriter`: non-blocking log writer using `SizedQueue` and a dedicated background thread
- Async mode enabled by default on `setup(async: true)` — log calls return immediately
- Configurable buffer size via `Legion::Settings[:logging, :async, :buffer_size]` (default: 10,000)
- Back-pressure: callers block when buffer is full (preserves log completeness)
- `fatal` calls always bypass the async queue (synchronous write)
- `async?`, `start_async_writer`, `stop_async_writer` methods on both singleton and Logger instances
- Hook callbacks (`on_error`, `on_warn`) fire on the writer thread; event context captured on caller thread

### Changed
- `setup` method now accepts `async:` keyword (default: `true`)
- `Logger.new` now accepts `async:` keyword (default: `false` for backward compatibility)

## [1.2.8] - 2026-03-22

### Changed
- Added `warn` output to all silent rescue blocks in builder.rb, event_builder.rb, hooks.rb, redactor.rb, and siem_exporter.rb

## v1.2.7

### Added
- `Legion::Logging::Hooks`: callback registry for fatal/error/warn log events
- `Legion::Logging::EventBuilder`: structured event payload builder with caller, exception, lex, and gem metadata
- `on_fatal`, `on_error`, `on_warn` registration methods on `Legion::Logging`
- `enable_hooks!`, `disable_hooks!`, `clear_hooks!` control methods
- Hook dispatch wired into `fatal`, `error`, `warn` methods in `Methods` module

## v1.2.6

### Added
- `Legion::Logging::Redactor`: PII/PHI redaction module with built-in patterns for SSN, email, phone, MRN, DOB, and credit card numbers
- Sensitive field-name redaction: fields named `password`, `secret`, `token`, `api_key`, `authorization` are always fully redacted
- Recursive redaction of nested hashes and arrays
- Custom pattern support via `Legion::Settings[:logging, :redactor, :custom_patterns]`
- `Legion::Logging::Shipper`: structured log event forwarding to external collectors with batch buffering and level filtering
- `Legion::Logging::Shipper::FileTransport`: writes JSON-lines to rotated log files for pickup by Filebeat/Fluentd
- `Legion::Logging::Shipper::HttpTransport`: POSTs JSON batches to HTTP endpoints (Splunk HEC, ELK Logstash)
- All SIEM shipping features disabled by default; opt-in via `logging.shipper.enabled: true`

## v1.2.5

### Fixed
- Added `logger` gem as runtime dependency for Ruby 4.0 compatibility (removed from default gems)

## v1.2.4

### Fixed
- Expand `~` in log_file paths with `File.expand_path` (fixes `Errno::ENOENT` for paths like `~/.legionio/logs/legion.log`)
- Auto-create parent directories for log files with `FileUtils.mkdir_p`

## v1.2.3

### Changed
- `Builder#text_format` now accepts `lex_segments:` array and formats it as stacked brackets (e.g. `[agentic][cognitive][anchor]`)
- Falls back to legacy `lex:` string kwarg for backward compatibility with existing callers
- `lex: nil` no longer produces a spurious `[]` bracket in log output

## v1.2.2

### Added
- `Legion::Logging::SIEMExporter`: Splunk HEC and ELK log shipping with PHI/PII redaction
- `redact_phi` strips SSN, phone, MRN, and DOB patterns from log text
- `format_for_elk` produces ELK-compatible event hashes

## v1.2.0
Moving from BitBucket to GitHub. All git history is reset from this point on