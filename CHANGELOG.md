# Legion::Logging Changelog

## [1.5.0] - 2026-04-02

### Added
- `Legion::Logging.current_settings` and `.configuration_generation` so helper mixins can refresh memoized tagged loggers after runtime reconfiguration
- Component logger overrides from local `settings`, top-level `Legion::Settings[component]`, and `Legion::Settings.dig(:extensions, component)` for `log_level`, `trace`, `trace_size`, and `extended`
- `Methods#emit_tagged` / `TaggedLogger#dispatch` path so component-level loggers can emit with their own level while preserving tagged context
- Fallback exception event construction in `Helper#handle_exception` when structured exception support is unavailable

### Changed
- `setup` and `Builder#log_level` now default to `debug`
- Default helper/tagged logger behavior enables trace and extended metadata
- `Helper#log` rebuilds memoized `TaggedLogger` instances when logging configuration changes
- Runtime logger settings take precedence over loaded global settings for helper-mixed components

### Fixed
- `setup(async: true)` now tolerates boolean `logging.async` settings without probing for `buffer_size`
- Exception stdout/file output now falls back safely when singleton logger helpers are unavailable
- Structured exception publishing is skipped when the exception writer/EventBuilder path is unavailable
- `TaggedLogger#unknown` falls back to `debug` output when `Legion::Logging.unknown` is unavailable

## [1.4.3] - 2026-04-01

### Added
- `TaggedLogger` lightweight proxy: delegates to singleton for shared stdout/file/async output
- `Helper#derive_log_segments` with class-level `SEGMENT_CACHE` — auto-derives `[llm][router]` from namespace
- `Helper#with_log_context` for block-scoped method name thread-locals (`{dispatch}` in log output)
- `Helper#handle_exception` with direct EventBuilder calls, per-line Rainbow coloring, structured AMQP publish
- `Helper.current_log_method`, `.current_log_segments`, `.current_context` thread-local readers
- `Legion::Logging::Settings` module with logger defaults
- `COMPONENT_MAP` with 18 component types (runners, actors, hooks, absorbers, tools, adapters, middleware, etc.)
- `EXCEPTION_COLORS` map for per-level exception coloring (bold first line, faint backtrace)
- `Thread.current[:legion_context]` support for wire protocol fields (task_id, conversation_id, chain_id)
- Redaction applied to exception stdout output when redaction is enabled
- Method context (`legion_log_method`) included in structured exception events
- `AsyncWriter::LogEntry` carries `segments` and `method_ctx` for thread-local propagation to writer thread
- `Builder#resolve_lex_tag` and `#build_runner_trace` extracted from `text_format`

### Changed
- `Helper#log` returns `TaggedLogger` instead of `Logger.new` (shared output, one async thread)
- `Helper#log_name`/`gem_name`/`gem_spec` replace `log_lex_name`/`lex_gem_name`/`gem_spec_for_lex` with multi-prefix resolution
- `gem_name` and `gem_spec` memoized per instance
- `COMPONENT_REGEX` in Methods expanded from 5 to 18 component types
- `build_writer_context` reads `Thread.current[:legion_log_segments]` instead of stale `@lex_segments` ivar
- `Builder#output` delegates to `set_log` (was parallel implementation)
- `Builder#caller_locations` allocates single frame instead of full stack
- Unknown log level strings default to INFO instead of DEBUG
- `EventBuilder#legion_versions` and `#resolve_gem_spec` memoized
- `EXCEPTION_PRIORITY` extracted to frozen constant in Methods (was inline hash allocation per call)
- `text_format` and `json_format` in Builder read thread-locals for segments and method context

### Fixed
- `fire_log_writer` rescue no longer references undefined `routing_key` variable
- Splunk auth header in `http_transport` — `apply_auth` receives actual URI instead of always evaluating against `URI('/')`
- `TaggedLogger#initialize` accepts `**_opts` splat for unexpected settings keys
- `TaggedLogger#trace` guards nil `size` to prevent `TypeError` on `caller_locations`

### Removed
- `TaggedLogger#runner_exception` (runner business logic, not logging concern)
- `TaggedLogger#log_exception` (use `Helper#handle_exception` instead)
- `Builder#log_level` no-op `@log = log` self-assignment

## [1.4.2] - 2026-03-28

### Added
- `Legion::Logging::CategoryRegistry` module: extension-defined event category registration with `register_category`, `registered_categories`, `category_registered?`, and `category_info` methods
- `Legion::Logging.register_category` and `Legion::Logging.registered_categories` delegate methods on the top-level module
- `category:` keyword argument on `EventBuilder.build` — emits `category` field in structured log events when provided
- `SIEMExporter.format_for_elk` now includes `category` field when the event hash carries `:category` or `"category"`

## [1.4.1] - 2026-03-27

### Fixed
- `require 'time'` added to `event_builder.rb` so `Time#iso8601` is always available in minimal Ruby environments
- `log_writer` / `exception_writer` accessors no longer memoize the no-op default via `||=`; `@log_writer` stays `nil` until a real writer is assigned, which allows `build_writer_context` to correctly short-circuit event building when no writer is configured
- README writer lambda examples updated to show correct keyword argument signatures matching actual call sites

## [1.4.0] - 2026-03-27

### Added
- `log_exception` method in `Methods` — single call for complete structured exception events
- `EventBuilder.build_exception` — builds rich exception payloads with fingerprint, versions, flat caller keys
- `EventBuilder.fingerprint` — MD5 fingerprint of stable error fields for dedup
- `log_writer` / `exception_writer` pluggable lambda slots on `Legion::Logging`
- Size enforcement: 4KB message cap, 8KB payload_summary cap, 64KB total cap
- Vault token, JWT, lease ID, and URI patterns added to Redactor

### Removed
- `Legion::Logging::Hooks` module (`on_fatal`, `on_error`, `on_warn`, `enable_hooks!`, `disable_hooks!`, `clear_hooks!`)
- Hooks replaced by `log_writer` and `exception_writer` lambdas

### Changed
- `AsyncWriter::LogEntry` uses `writer_context` field instead of `hook_context`
- `runner_exception` now delegates to `log_exception` internally

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
