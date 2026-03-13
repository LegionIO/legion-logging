# legion-logging: Logging Framework for LegionIO

**Repository Level 3 Documentation**
- **Category**: `/Users/miverso2/rubymine/arc/CLAUDE.md`
- **Workspace**: `/Users/miverso2/rubymine/CLAUDE.md`

## Purpose

Ruby logging class for the LegionIO framework. Provides colorized console output via Rainbow and a consistent logging interface across all Legion gems and extensions.

**GitHub**: https://github.com/Optum/legion-logging
**License**: Apache-2.0

## Architecture

```
Legion::Logging (singleton module)
├── Methods    # Log level methods: debug, info, warn, error, fatal, unknown
├── Builder    # Output destination (stdout/file), log level, formatter
├── Logger     # Core logger configuration and setup
└── Version    # VERSION constant
```

### Key Design Patterns

- **Singleton Module**: `Legion::Logging` uses `class << self` - called directly: `Legion::Logging.info("msg")`
- **Rainbow Colorization**: Console output uses Rainbow gem for colored terminal output
- **Setup Method**: `Legion::Logging.setup(log_file:, level:)` configures output destination and level
- **Shared Interface**: Same method signature (`info`, `warn`, `error`, etc.) as `Optum::Logger` - the two gems share conceptual patterns

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
| `lib/legion/logging/version.rb` | VERSION constant |

## Role in LegionIO

**Foundational gem** - used by `legion-cache`, `legion-data`, and `LegionIO` as a direct dependency. First module initialized during `Legion::Service` startup.

---

**Maintained By**: Matthew Iverson (@Esity)
