# Changelog

## [Unreleased]

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
