# Changelog

## [Unreleased]

### Fixed

- `authenticate` with a different token kept the previous identity's refresh token and
  sign-in credentials.
- Over HTTP, `signin`, `signup`, `authenticate`, `refresh` and `revoke` sent the current
  access token as a bearer header, so once it had expired the server refused them with 401.
- Clearing the namespace or database with `use` left the SDK holding a `NONE` value, which
  HTTP connections then sent as the namespace or database header.
- README examples that did not run: the Queries example selected from a table before
  creating it and called an undefined function, the Live Queries example watched a table
  that did not exist, the geometry example used undefined variables, and the error handling
  example expected `QueryError` for a parse error (the server reports `ValidationError`).
  Every Ruby example in the README now runs in CI against a real server.

- Record-level CRUD targeted the wrong table: `RecordID`s were sent as strings, which the
  server reads as a table name, so `select("person:alice")` read a table called
  `person:alice`. Record ids and tables are now sent as typed CBOR values (tags 8 and 7).

- UUIDs decoded to `String` and were never encoded, so uuid-keyed record ids and uuid
  parameters did not survive a round trip. They are now `SurrealDB::Uuid` (tag 37).

- Sessions were unusable: `attach` sent no session id and the request envelope had no
  `session` field, so every request ran in the default session.

- Transactions were unusable: the envelope had no `txn` field and `commit`/`cancel` were
  sent without the transaction id, so the server rejected them and queries never ran inside
  the transaction.

- `import_data`/`export_data` called RPC methods the server does not have. `import` and
  `export` now use the HTTP `/import` and `/export` routes (from any connection type), and a
  failed import raises `ImportError` listing the failed statements.
- `QueryResult#error` was empty for failed statements; it now carries the server's message,
  with `kind`, `details` and `to_error`.

- `set`/`let`/`unset` were silently lost over HTTP, where each request runs in a fresh
  server session. The client now keeps the variables and sends them with every query.

- WebSocket `connect` could hang forever: the TCP connect and the handshake reads had no
  deadline. Opening a connection (TCP, TLS and the WebSocket upgrade) now shares one
  `connect_timeout` (defaults to `timeout`), and connection failures raise `ConnectionError`
  instead of raw `Errno` exceptions.

- HTTP requests failed with `EOFError`/`EPIPE` when the kept-alive socket had been closed by
  the server. The request is now sent once more on a fresh socket when a reused socket dies
  before any response arrives. One failed request no longer marks the HTTP client as
  permanently disconnected, and an HTTP 401 is reported as `NotAllowedError` with the
  server's message instead of a bare `ConnectionError`.

- Reconnection repeated requests that may already have run, and lost the rest of the
  session. A dropped request was retried whatever it was, so a `create` or `query` in flight
  could run twice; attached sessions, live queries and transactions were not considered at
  all. Now a request that was never sent is sent once the connection is back, one that was
  in flight is repeated only when that is harmless (reads, `use`, variables, `authenticate`)
  and otherwise raises `RequestInterruptedError`, and a transaction is never resumed on the
  new connection. Every attached session is restored with its own state, an expired token
  falls back to the last `signin` (a `signup` is never repeated), and live queries started
  with `live` are issued again and keep delivering under the id the caller holds. The
  reconnect starts as soon as the drop is noticed.

### Added

- `gql` runs ISO GQL queries (the `gql` RPC method) and returns results like `query`.
  It needs SurrealDB 3.3, or 3.2 with the experimental `gql` capability enabled
  (`--allow-experimental gql`, which otherwise raises `NotAllowedError`); older servers
  raise `UnsupportedError`.
- `api(prefix)` invokes user-defined APIs (`DEFINE API`) through `api::invoke`, with
  `get`/`post`/`put`/`patch`/`delete`/`invoke` and per-object headers, returning an
  `ApiResponse` whose `value` raises `ApiError` for a non-2xx status.

- `query_stream` yields a query's results as `QueryChunk`s while the server produces them
  (`query_stream` RPC, WebSocket, SurrealDB 3.3+), on a client, session or transaction.
  Leaving the block early sends `query_cancel`. Other connections and older servers run the
  query buffered and yield the same chunks.

- Per-call timeouts: `query`, `query_raw` and `send_rpc` take `timeout:`, and
  `with_timeout(seconds) { ... }` applies a timeout to every request in the block on that
  connection, including its sessions and transactions.

- `connect` checks the server version and raises `UnsupportedVersionError` unless it is
  at least 3.0.0 and below 5.0.0 (`version_check: false` skips the check);
  `Client#server_version` holds the reported version.

- `refresh` and `revoke` for access methods defined `WITH REFRESH`; `authenticate` also
  accepts the `{"access", "refresh"}` pair `signin`/`signup` return.
- Automatic token renewal: shortly before a session's access token expires (read from its
  `exp` claim), the SDK renews it with the refresh token, or by signing in again with the
  last `signin` credentials. Previously an expired token left a WebSocket session running
  unauthenticated and made HTTP requests fail. Configure with `token_refresh_margin:`
  (default 60s, capped at a quarter of the token's lifetime) or turn off with
  `renew_tokens: false`. Reconnection also falls back to the refresh token.

- `use` changes the namespace or the database alone and can clear either: a String selects
  it, `nil` clears it and `SurrealDB::NONE` (the default) leaves it unchanged, positionally
  or as `namespace:` / `database:` keywords. It returns the resulting namespace and database.
- `reset` returns the session to its initial state (signed out, nothing selected, no
  variables), as the server's `reset` method does; the server also kills the session's live
  queries and cancels its transactions.
- `health` checks the server's HTTP `/health` route (raising when it is unhealthy or
  unreachable) and `healthy?` answers true or false.

- Interactive transactions as objects: `begin_transaction` (on a `Client` or `Session`)
  returns a `SurrealDB::Transaction` whose query and CRUD calls carry the transaction id;
  `commit`/`cancel` finish it. The block form commits on return and cancels on error.
- Sessions as objects: `Client#new_session` (alias `attach`) returns a `SurrealDB::Session`
  that supports every request method and runs them in its own server session.
  `Client#fork_session` / `Session#fork_session` copy namespace, database, variables and
  credentials. `Client#sessions` lists attached sessions. Sessions work over HTTP as well as
  WebSocket.
- `SurrealDB::Uuid` (with `.parse`, `.v4`, `.v7`), `SurrealDB::FileRef` (tag 55) and Ruby
  `Set` support (tag 56), plus decoding of RFC 3339 datetime strings (tag 0).

### Changed

- **Breaking:** `query` returns one result per statement (`[1, [{...}]]`) instead of the
  server's raw `{status, time, result}` envelopes, and raises when a statement fails, with
  the first failed statement's error as the `ServerError` subclass for its kind (previously
  failed statements were returned silently). `query_raw` still reports every statement.
- WebSocket connections reconnect by default; pass `reconnect: false` to opt out.
- **Breaking:** `begin_transaction` returns a `Transaction`; `Client#commit`/`#cancel` take
  the transaction (or its id).
- **Breaking:** `Client#attach` returns a `Session` instead of the raw server result, and
  `Client#detach` takes a `Session` (or its id).
- **Breaking:** UUID values, including live query ids, decode to `SurrealDB::Uuid` instead
  of `String`. Use `#to_s` for the text form.
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
