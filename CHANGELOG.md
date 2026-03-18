# Legion::Logging Changelog

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