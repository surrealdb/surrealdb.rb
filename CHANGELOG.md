# Changelog

## [Unreleased]

### Fixed

- Embedded timeouts above 255 seconds wrapped around: the engine takes them as a `uint8_t`,
  so a `timeout` of 256 disabled the timeout and 300 became 44 seconds. Such timeouts now
  raise `ArgumentError`, fractions round up instead of truncating to 0 (no timeout), and
  `query_timeout:` / `transaction_timeout:` can be set separately.

## [0.7.0] - 2026-04-01

### Added

- Initial SDK implementation with WebSocket and HTTP transports
- CBOR serialization with custom SurrealDB type tags
- Full CRUD operations (create, select, insert, update, upsert, merge, patch, delete)
- Raw SurrealQL query support with parameterized variables
- Authentication (signin, signup, authenticate, invalidate)
- Live query support over WebSocket
- SurrealDB types: RecordID, Table, Duration, None, Range, Geometry
- Structured error hierarchy matching SurrealDB server errors
