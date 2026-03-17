# Legion::Logging Changelog

## v1.2.2

### Added
- `Legion::Logging::SIEMExporter`: Splunk HEC and ELK log shipping with PHI/PII redaction
- `redact_phi` strips SSN, phone, MRN, and DOB patterns from log text
- `format_for_elk` produces ELK-compatible event hashes

## v1.2.0
Moving from BitBucket to GitHub. All git history is reset from this point on