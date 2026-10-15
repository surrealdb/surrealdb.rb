# CLAUDE.md

Project context for AI assistants working on the SurrealDB Ruby SDK.

## Commands

```bash
bundle install              # Install dependencies
bundle exec rspec spec/unit # Run unit tests (no server needed)
bundle exec rspec           # Run all non-integration tests
bundle exec rubocop         # Run linter
bundle exec rake            # Run lint + unit tests (default task)

# Integration tests require a running SurrealDB instance:
docker run --rm -p 8000:8000 surrealdb/surrealdb:latest start --user root --pass root --allow-all
bundle exec rspec spec/integration
```

## Architecture

This SDK follows the same connection-interface pattern as the Go (`surrealdb.go`) and Python (`surrealdb.py`) SDKs.

### Layer structure

```
SurrealDB::Client                  — Public API (CRUD, query, auth, live queries)
SurrealDB::QueryResult             — Per-statement result wrapper for query_raw
SurrealDB::Protocol::RPC           — RPC request/response framing over CBOR
SurrealDB::CBOR::*                 — CBOR encode/decode with custom SurrealDB type tags
SurrealDB::Connections::WebSocket  — WebSocket transport (ConditionVariable-based, fiber-compatible)
SurrealDB::Connections::HTTP       — HTTP transport (Net::HTTP)
SurrealDB::Connections::ReliableWebSocket — Auto-reconnect wrapper with state replay
SurrealDB::Connections::Embedded   — FFI to libsurrealdb_c (opt-in via require "surrealdb/embedded")
SurrealDB::Native::*               — FFI bindings and platform detection (loaded by embedded.rb)
```

- `Client` is the user-facing class. It delegates all operations to a `Connection`.
- `Protocol::RPC` generates request IDs, encodes requests as CBOR maps `{id, method, params}`, and decodes CBOR responses.
- `CBOR::Encoder` converts Ruby objects (including SurrealDB types) to CBOR bytes. `CBOR::Decoder` reverses the process.
- Connections implement `#connect`, `#close`, and `#send_request(method, params)`.

### Connection types

URL scheme determines the transport:
- `ws://` / `wss://` → `Connections::WebSocket` (background reader thread, live queries, ConditionVariable-based)
- `http://` / `https://` → `Connections::HTTP` (synchronous POST to /rpc)
- `mem://` / `surrealkv://` / `file://` → `Connections::Embedded` (FFI to libsurrealdb_c, opt-in)
- Pass `reconnect: true` to wrap WebSocket in `ReliableWebSocket` (auto-reconnect with state replay)

### CBOR custom tags

SurrealDB encodes custom types via numbered CBOR tags. See `lib/surrealdb/cbor/tags.rb` for the full mapping. Key tags: 6=NONE, 7=Table, 8=RecordID, 12=Datetime, 14=Duration, 88-94=Geometry.

## Key design decisions

1. **RPC API over direct C API**: The C library (`surrealdb.c`) exposes both a full C API (~40 functions) and a minimal RPC API (4 functions that pass CBOR bytes). We use the CBOR RPC approach because it keeps the FFI surface tiny and lets us handle all serialization in Ruby. This matches the Go SDK's approach.

2. **CBOR, not JSON**: SurrealDB's RPC protocol uses CBOR for all transports (WebSocket, HTTP, embedded). The `cbor` gem handles encoding/decoding; we add a pre/post-processing step for SurrealDB's custom tagged types.

3. **Structured error hierarchy**: Server errors carry `kind`, `details`, and a `cause` chain matching SurrealDB v3's structured error format. We also handle legacy v2 code+message errors.

4. **Thread safety**: Neither connection type is safe for concurrent use from multiple threads. The WebSocket connection uses a `@write_mutex` to prevent frame corruption and a `@mutex` for pending-request routing, but the overall request lifecycle is not atomic. The HTTP connection shares `Net::HTTP` and header state. Users needing concurrency should use one Client per thread.

5. **Logger**: `SurrealDB.configuration.logger` is wired into both connections. WebSocket logs connection events at `:debug` level and dropped messages at `:warn`. HTTP logs connect/close at `:debug`. The logger must never receive credentials or auth tokens.

6. **`send_rpc` escape hatch**: `Client#send_rpc(method, params)` forwards directly to the connection, letting users call new or undocumented RPC methods without waiting for SDK wrapper methods.

7. **Sessions**: the request envelope is `{id, method, params, session?, txn?}`. `Client#new_session` generates a UUID, sends `attach` with it in the envelope, and returns a `Session` whose requests carry that id. `Client` and `Session` share `RequestMethods`; each implements `rpc`. Connections keep a `SessionState` per session (ns/db, variables, tokens) updated after each successful request; it backs `fork_session`, HTTP headers and reconnect replay. Sessions work over WebSocket and HTTP.

   **Transactions** (WebSocket only; HTTP has no begin/commit): the envelope gains `txn?`. `begin_transaction` returns a `Transaction` (includes `QueryMethods` only) whose requests carry `session` and `txn`; `commit`/`cancel` send `[txn_id]` as params. The block form commits on return and cancels on error.

8. **Embedded connection** (opt-in): `require "surrealdb/embedded"` loads FFI bindings to `libsurrealdb_c`. Uses the same CBOR RPC protocol as WebSocket/HTTP -- the C library only handles byte transport. Only 8 C functions are wrapped. All FFI calls use `blocking: true` to release the GVL.

9. **Async/Fiber compatibility**: WebSocket `send_request` uses `ConditionVariable#wait` instead of busy-wait polling. This is compatible with Ruby's Fiber scheduler (Ruby 3.1+), so the SDK works transparently with the `async` gem and similar frameworks.

10. **Reconnection**: `Connections::ReliableWebSocket` wraps a WebSocket with auto-reconnect. Tracks `use`, `signin`/`signup`/`authenticate`, `let` calls and replays them after reconnecting. Uses exponential backoff.

11. **`query_raw`**: Returns `Array<QueryResult>` with per-statement `status`, `time`, `result`, `error`. Use when you need to inspect individual statement outcomes in multi-statement queries.

## Dependencies

- `cbor` (~> 0.5) — C-extension CBOR codec. `CBOR::Tagged` is used for custom tags.
- `websocket-driver` (~> 0.7) — WebSocket protocol (handshake, framing). Transport-agnostic; we provide the TCP/SSL socket.

## Code conventions

- All files start with `# frozen_string_literal: true`
- YARD doc comments on public methods
- RuboCop enforced (see `.rubocop.yml`)
- RSpec for testing, `describe`/`context`/`it` style
- Integration tests tagged `:integration`, require a Docker SurrealDB instance
- Shared examples in `spec/support/shared_examples.rb` run CRUD/query/auth tests across both transports

## Testing

- **Unit tests** (`spec/unit/`): Test CBOR round-trips, model parsing, RPC encoding, error mapping. No server needed.
- **Integration tests** (`spec/integration/`): Test against a live SurrealDB. Organized by transport (`websocket/`, `http/`). Use shared examples for cross-transport parity.
- **Environment variables**: `SURREALDB_WS_URL`, `SURREALDB_HTTP_URL`, `SURREALDB_USER`, `SURREALDB_PASS`, `SURREALDB_NS`, `SURREALDB_DB`.

## File layout

```
lib/surrealdb.rb                    Entry point
lib/surrealdb/client.rb             Public API
lib/surrealdb/query_result.rb       Per-statement result wrapper
lib/surrealdb/errors.rb             Error hierarchy
lib/surrealdb/models/               RecordID, Table, Duration, None, Range, Geometry
lib/surrealdb/cbor/                 Tags, Encoder, Decoder
lib/surrealdb/protocol/             RPC, Methods, Response
lib/surrealdb/connections/          Base, WebSocket, HTTP, ReliableWebSocket
lib/surrealdb/embedded.rb           Opt-in entrypoint for embedded connection
lib/surrealdb/native/               FFI bindings (ffi.rb) + platform detection (platform.rb)
lib/surrealdb/connections/embedded.rb  Embedded connection (loaded by embedded.rb)
surrealdb-embedded.gemspec          Separate gem for embedded support
spec/unit/                          Unit tests
spec/unit/connections/              Connection-specific unit tests
spec/integration/                   Integration tests (websocket/, http/, embedded/)
spec/support/                       Helpers, shared examples
```
