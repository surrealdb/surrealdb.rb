# Changelog

## [Unreleased]

### Fixed

- Record-level CRUD targeted the wrong table: `RecordID`s were sent as strings, which the
  server reads as a table name, so `select("person:alice")` read a table called
  `person:alice`. Record ids and tables are now sent as typed CBOR values (tags 8 and 7).

### Changed

- **Breaking:** a String target is always a table name. Strings containing `:` raise
  `ArgumentError` instead of being guessed at. Use `RecordID.new`, `RecordID.parse`, or the
  new `StringRecordID` (parsed by the server). `relate` requires record ids for both ends.
- `RecordID#to_s` escapes table names and digit-only string keys the way SurrealQL does, and
  `RecordID.parse` handles escaped tables and refuses ids it cannot parse on the client.

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
