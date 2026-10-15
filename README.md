# surrealdb.rb

The official SurrealDB SDK for Ruby.

[![CI](https://github.com/surrealdb/surrealdb.rb/actions/workflows/ci.yml/badge.svg)](https://github.com/surrealdb/surrealdb.rb/actions/workflows/ci.yml)
[![Gem Version](https://badge.fury.io/rb/surrealdb.svg)](https://badge.fury.io/rb/surrealdb)
[![License](https://img.shields.io/badge/license-Apache_2.0-blue.svg)](LICENSE)

## Installation

```bash
gem install surrealdb
```

Or add to your Gemfile:

```ruby
gem "surrealdb"
```

## Quick Start

```ruby
require "surrealdb"

SurrealDB.connect("ws://localhost:8000") do |db|
  db.signin("user" => "root", "pass" => "root")
  db.use("test", "test")

  # Create
  db.create("person", { "name" => "Alice", "age" => 30 })

  # Select
  people = db.select("person")

  # Query
  results = db.query("SELECT * FROM person WHERE age > $min", { "min" => 25 })

  # Record ids are typed values; a plain string is always a table name
  alice = SurrealDB::RecordID.new("person", "alice")
  db.create(alice, { "name" => "Alice", "age" => 31 })

  # Update
  db.merge(alice, { "email" => "alice@example.com" })

  # Delete
  db.delete(alice)
end
```

## Connection Types

The SDK supports three transport protocols, selected automatically by URL scheme:

| Scheme | Transport | Live Queries | Sessions | Requires |
|--------|-----------|:------------:|:--------:|----------|
| `ws://`, `wss://` | WebSocket | Yes | Yes | -- |
| `http://`, `https://` | HTTP | No | Yes | -- |
| `mem://`, `surrealkv://`, `file://` | Embedded | Yes | Yes | `surrealdb-embedded` gem |

```ruby
# WebSocket (recommended for most use cases)
client = SurrealDB::Client.new("ws://localhost:8000")

# HTTP (stateless, simpler)
client = SurrealDB::Client.new("http://localhost:8000")
```

For in-process use without a server, see [Embedded Database](#embedded-database).

## Namespace, Database and Session State

```ruby
SurrealDB.connect("ws://localhost:8000") do |db|
  db.signin("user" => "root", "pass" => "root")

  db.use("test", "test")      # => { "namespace" => "test", "database" => "test" }
  db.use(database: "staging") # change only the database
  db.use("other")             # change only the namespace
  db.use(database: nil)       # clear the database

  # Back to a fresh session: signed out, nothing selected, no variables,
  # live queries killed and open transactions cancelled
  db.reset

  db.health   # raises unless the server's /health route reports it healthy
  db.healthy? # => true or false
end
```

## Authentication

```ruby
SurrealDB.connect("ws://localhost:8000") do |db|
  # Root authentication
  db.signin("user" => "root", "pass" => "root")

  # Namespace authentication
  db.signin("user" => "ns_user", "pass" => "ns_pass", "ns" => "my_namespace")

  # Database authentication
  db.signin("user" => "db_user", "pass" => "db_pass", "ns" => "my_namespace", "db" => "my_database")

  # Record user authentication
  token = db.signup(
    "ns" => "my_namespace",
    "db" => "my_database",
    "ac" => "user_access",
    "username" => "alice",
    "password" => "password123"
  )

  # Token authentication (a token, or the {"access", "refresh"} pair signin returns)
  db.authenticate(token)

  # Invalidate session
  db.invalidate
end
```

### Token refresh

When an access method is defined `WITH REFRESH`, `signin` and `signup` return
`{"access" => ..., "refresh" => ...}`. Sessions renew their access token on
their own shortly before it expires: with the refresh token when they have one,
otherwise by signing in again with the credentials they last signed in with.
Without this, a WebSocket session whose token expires carries on unauthenticated.

```ruby
client = SurrealDB::Client.new("ws://localhost:8000",
  token_refresh_margin: 60, # renew this many seconds before expiry (default 60)
  renew_tokens: true        # set to false to manage tokens yourself
)

client.connect
client.signup(
  "ns" => "my_namespace", "db" => "my_database", "ac" => "user_access",
  "username" => "bob", "password" => "password123"
) # => { "access" => "...", "refresh" => "..." }

client.refresh # exchange the refresh token for new tokens now
client.revoke  # revoke the refresh token; the access token lasts until it expires
```

## CRUD Operations

```ruby
SurrealDB.connect("ws://localhost:8000") do |db|
  db.signin("user" => "root", "pass" => "root")
  db.use("test", "test")

  # Create a record (auto-generated ID)
  person = db.create("person", { "name" => "Alice", "age" => 30 })

  # Create with specific ID
  bob = SurrealDB::RecordID.new("person", "bob")
  db.create(bob, { "name" => "Bob", "age" => 25 })

  # Select all records from a table
  people = db.select("person")

  # Select a specific record
  alice = db.select(SurrealDB::RecordID.new("person", "alice"))

  # Insert multiple records
  db.insert("person", [
    { "name" => "Charlie", "age" => 35 },
    { "name" => "Diana", "age" => 28 }
  ])

  # Update (full replace)
  db.update(bob, { "name" => "Bob", "age" => 26, "email" => "bob@example.com" })

  # Upsert (insert or update)
  db.upsert(SurrealDB::RecordID.new("person", "eve"), { "name" => "Eve", "age" => 22 })

  # Merge (partial update)
  db.merge(bob, { "email" => "bob@newmail.com" })

  # Patch (JSON Patch)
  db.patch(bob, [
    { "op" => "replace", "path" => "/age", "value" => 27 }
  ])

  # Delete a record
  db.delete(bob)

  # Delete all records from a table
  db.delete("person")

  # Create a relation
  db.relate(SurrealDB::RecordID.new("person", "alice"), "knows", bob, { "since" => 2024 })
end
```

### Record ids and strings

A plain string is always a table name. Strings are never parsed as record ids
implicitly, so `db.select("person:alice")` raises `ArgumentError` instead of
silently targeting a table called `person:alice`. Say what you mean instead:

```ruby
SurrealDB::RecordID.new("person", "alice")           # build it
SurrealDB::RecordID.parse("person:alice")            # parse it on the client
SurrealDB::StringRecordID.new("temp:['London', 1]")  # let the server parse it
```

## Queries

```ruby
SurrealDB.connect("ws://localhost:8000") do |db|
  db.signin("user" => "root", "pass" => "root")
  db.use("test", "test")

  # Multi-statement query: one result per statement
  created_alice, created_bob, people = db.query(<<~SQL)
    CREATE person:alice SET name = 'Alice', age = 30;
    CREATE person:bob SET name = 'Bob', age = 25;
    SELECT * FROM person;
  SQL

  # Parameterized query
  adults, = db.query(
    "SELECT * FROM person WHERE age > $min_age AND name = $name",
    { "min_age" => 25, "name" => "Alice" }
  )

  # Connection-scoped variables
  db.set("current_user", "Alice")
  mine, = db.query("SELECT * FROM person WHERE name = $current_user")
  db.unset("current_user")

  # Run a function
  db.run("string::uppercase", "hello") # => "HELLO"
  db.query("DEFINE FUNCTION OVERWRITE fn::greet($name: string) { RETURN 'Hello, ' + $name }")
  db.run("fn::greet", "Alice")         # => "Hello, Alice"
end
```

`query` raises when any statement fails, with the error of the first failed
statement (see [Error Handling](#error-handling)). Statements before it may
already have run; use `query_raw` to see each statement's outcome.

## Structured Query Results

Use `query_raw` to get per-statement metadata (status, timing, errors) for multi-statement queries:

```ruby
results = db.query_raw("CREATE person:a SET name = 'Alice'; SELECT * FROM missing_table;")
results.each do |qr|
  if qr.ok?
    puts "#{qr.time}: #{qr.result}"
  else
    puts "Error: #{qr.error}"
  end
end
```

## Sessions

One connection can hold several server sessions, each with its own namespace,
database, variables and credentials. Requests made on the client itself run in
the connection's default session.

```ruby
SurrealDB.connect("ws://localhost:8000") do |db|
  db.signin("user" => "root", "pass" => "root")
  db.use("test", "test")

  # A fresh session starts empty, and is detached when the block returns
  db.new_session do |session|
    session.use("test", "other")
    session.signin("user" => "root", "pass" => "root")
    session.query_raw("RETURN session::db()")  # runs in "other"
  end

  # A fork starts with a copy of the default session's state
  fork = db.fork_session
  fork.set("tenant", "acme")
  fork.close

  db.sessions # => ids of the sessions attached on this connection (not over HTTP)
end
```

## Transactions

Interactive transactions run over WebSocket. Nothing written inside one is
visible outside it until it commits.

```ruby
SurrealDB.connect("ws://localhost:8000") do |db|
  db.signin("user" => "root", "pass" => "root")
  db.use("test", "test")

  # Block form: commits when the block returns, cancels if it raises
  db.begin_transaction do |tx|
    tx.create(SurrealDB::RecordID.new("account", "a"), { "balance" => 100 })
    tx.create(SurrealDB::RecordID.new("account", "b"), { "balance" => 0 })
  end

  # Or manage it yourself
  tx = db.begin_transaction
  tx.query("UPDATE account:a SET balance -= 10")
  tx.query("UPDATE account:b SET balance += 10")
  tx.commit # or tx.cancel

  # Sessions have their own transactions
  db.fork_session { |s| s.begin_transaction { |stx| stx.select("account") } }
end
```

## Import and Export

Import and export use the server's HTTP `/import` and `/export` routes, with
the current namespace, database and credentials. They work on WebSocket and
HTTP connections alike.

```ruby
SurrealDB.connect("ws://localhost:8000") do |db|
  db.signin("user" => "root", "pass" => "root")
  db.use("test", "test")

  sql = db.export                                  # the whole database
  sql = db.export(tables: ["person"], users: false) # choose what to export
  File.open("backup.surql", "w") { |f| db.export { |chunk| f.write(chunk) } } # stream it

  # Imports must start with OPTION IMPORT; (exports already do)
  db.import(sql)
  File.open("backup.surql") { |f| db.import(f) }
rescue SurrealDB::ImportError => e
  # An import is not atomic: statements before the failures stay applied
  puts "#{e.count} statements failed: #{e.failures.map(&:message)}"
end
```

## Embedded Database

For in-process usage without a separate server, install the embedded gem:

```bash
gem install surrealdb-embedded
```

Then opt in with an extra require:

```ruby
require "surrealdb"
require "surrealdb/embedded"

SurrealDB.connect("mem://") do |db|
  db.use("test", "test")
  db.create("person", { "name" => "Alice" })
end
```

Supported schemes: `mem://` (in-memory), `surrealkv://path` (persistent), `file://path` (file-based).

Requires `libsurrealdb_c` installed on the system or pointed to via `SURREALDB_LIB_PATH`.

## Automatic Reconnection

WebSocket connections reconnect automatically, with exponential backoff, as soon as a
dropped connection is noticed. Pass `reconnect: false` to turn this off.

```ruby
client = SurrealDB::Client.new("ws://localhost:8000",
  reconnect_max_retries: 5, # attempts before giving up
  reconnect_delay: 1.0      # base delay between attempts, doubled each time
)
client.connect
client.signin("user" => "root", "pass" => "root")
client.use("test", "test")
```

After reconnecting, the SDK restores what the server lost with the connection:

- the namespace, database, variables and credentials of the default session and of every
  attached session (an expired token falls back to the last `signin`; a `signup` is never
  repeated);
- live queries started with `live`, which keep delivering under the id you were given.

A request that was never sent is sent once the connection is back. A request that was in
flight when the connection dropped may already have run, so only harmless ones (reads,
`use`, variables, `authenticate`) are sent again; anything else raises
`SurrealDB::RequestInterruptedError`, and you decide whether to retry it:

```ruby
begin
  client.create("person", { "name" => "Alice" })
rescue SurrealDB::RequestInterruptedError
  # The connection is back, but the create may or may not have happened.
end
```

Transactions do not survive a reconnect: any further request in one raises
`RequestInterruptedError`, and nothing in it was committed. Live queries started by a
`LIVE SELECT` statement inside `query` are not restored.

## Live Queries

Live queries are supported over WebSocket and embedded connections.

```ruby
SurrealDB.connect("ws://localhost:8000") do |db|
  db.signin("user" => "root", "pass" => "root")
  db.use("test", "test")

  # Start a live query (the table must exist)
  db.query("DEFINE TABLE IF NOT EXISTS person SCHEMALESS")
  live_id = db.live("person")

  # Subscribe to notifications
  db.subscribe(live_id) do |notification|
    puts "Action: #{notification['action']}"
    puts "Result: #{notification['result']}"
  end

  # Changes to the table will trigger notifications
  db.create("person", { "name" => "Alice" })

  # Stop the live query
  db.kill(live_id)
end
```

## SurrealDB Types

The SDK provides Ruby types that map to SurrealDB's type system:

```ruby
# RecordID
rid = SurrealDB::RecordID.new("person", "alice")
rid = SurrealDB::RecordID.parse("person:alice")
rid.table  # => "person"
rid.id     # => "alice"

# Table
table = SurrealDB::Table.new("person")

# Uuid (CBOR tag 37); server UUIDs decode to this, never to String
uuid = SurrealDB::Uuid.v7
uuid = SurrealDB::Uuid.parse("0190d5ab-7c3e-7d2a-9f1b-123456789abc")
SurrealDB::RecordID.new("person", uuid)

# Set (CBOR tag 56) maps to Ruby's Set
Set[1, 2, 3]

# File pointer (CBOR tag 55), f"bucket:/key" in SurrealQL
SurrealDB::FileRef.new("avatars", "/alice.png")

# Duration
duration = SurrealDB::Duration.parse("1h30m")
duration.secs   # => 5400
duration.to_f   # => 5400.0

# None (distinct from nil/NULL)
SurrealDB::NONE

# Geometry
point = SurrealDB::GeometryPoint.new(-122.4194, 37.7749)
line = SurrealDB::GeometryLine.new(point, SurrealDB::GeometryPoint.new(-122.0, 37.5))
ring = SurrealDB::GeometryLine.new(
  SurrealDB::GeometryPoint.new(0, 0), SurrealDB::GeometryPoint.new(1, 0),
  SurrealDB::GeometryPoint.new(1, 1), SurrealDB::GeometryPoint.new(0, 0)
)
polygon = SurrealDB::GeometryPolygon.new(ring)

# Range
range = SurrealDB::Range.new(
  SurrealDB::BoundIncluded.new(1),
  SurrealDB::BoundExcluded.new(10)
)
```

## Error Handling

```ruby
begin
  db.query("SELEC * FROM person")
rescue SurrealDB::ValidationError => e
  puts "Invalid query: #{e.message}" # parse errors
rescue SurrealDB::QueryError => e
  puts "Query failed: #{e.message}"
rescue SurrealDB::ThrownError => e
  puts "THROW: #{e.message}"
rescue SurrealDB::NotFoundError => e
  puts "Not found: #{e.message}"
rescue SurrealDB::NotAllowedError => e
  puts "Permission denied: #{e.message}"
rescue SurrealDB::ServerError => e
  # Catch-all for server errors
  puts "Server error (#{e.kind}): #{e.message}"
  puts "Cause: #{e.server_cause.message}" if e.server_cause
rescue SurrealDB::ConnectionError => e
  puts "Connection lost: #{e.message}"
rescue SurrealDB::TimeoutError => e
  puts "Request timed out: #{e.message}"
end
```

## Server Versions

The SDK supports SurrealDB 3.0.0 up to (not including) 5.0.0. `connect` checks the
server's version and raises `SurrealDB::UnsupportedVersionError` outside that range;
pass `version_check: false` to connect anyway. `client.server_version` holds what the
server reported.

## Configuration

```ruby
require "logger" # from Ruby 3.5, add `gem "logger"` to your Gemfile

SurrealDB.configure do |config|
  config.timeout = 60  # seconds (default: 30)
  config.logger = Logger.new($stdout)
end

# Per-connection timeouts: requests, and opening the connection (TCP + TLS + handshake)
client = SurrealDB::Client.new("ws://localhost:8000", timeout: 10, connect_timeout: 5)
client.connect
client.signin("user" => "root", "pass" => "root")
client.use("test", "test")

# Per-call timeouts: for one query, or for everything in a block
client.query("RETURN time::now()", timeout: 2)
client.with_timeout(30) do
  client.query("SLEEP 100ms")
end
```

A timeout is how long the client waits: the request raises `SurrealDB::TimeoutError`, but
the server may still finish it. To stop a statement on the server, give it a `TIMEOUT`
clause. Embedded connections use the engine's own query timeout instead.

## Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/my-feature`)
3. Run the tests (`bundle exec rspec`)
4. Run the linter (`bundle exec rubocop`)
5. Commit your changes
6. Push to the branch
7. Create a Pull Request

### Running Integration Tests

Integration tests require a running SurrealDB instance:

```bash
docker run --rm -p 8000:8000 surrealdb/surrealdb:latest start --user root --pass root --allow-all
bundle exec rspec spec/integration
```

## Links

- [SurrealDB Documentation](https://surrealdb.com/docs)
- [SurrealDB Ruby SDK Docs](https://surrealdb.com/docs/sdk/ruby)
- [API Reference](https://rubydoc.info/gems/surrealdb)
- [GitHub Issues](https://github.com/surrealdb/surrealdb.rb/issues)
- [Discord](https://discord.gg/surrealdb)
