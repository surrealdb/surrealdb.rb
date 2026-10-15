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

# Embedded (in-process, no server needed)
require "surrealdb/embedded"
client = SurrealDB::Client.new("mem://")
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

  # Token authentication
  db.authenticate(token)

  # Invalidate session
  db.invalidate
end
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

  # Simple query
  results = db.query("SELECT * FROM person")

  # Parameterized query
  results = db.query(
    "SELECT * FROM person WHERE age > $min_age AND name = $name",
    { "min_age" => 25, "name" => "Alice" }
  )

  # Multi-statement query
  results = db.query(<<~SQL)
    CREATE person:alice SET name = 'Alice', age = 30;
    CREATE person:bob SET name = 'Bob', age = 25;
    SELECT * FROM person;
  SQL

  # Connection-scoped variables
  db.set("current_user", "alice")
  results = db.query("SELECT * FROM person WHERE name = $current_user")
  db.unset("current_user")

  # Run a SurrealDB function
  result = db.run("fn::my_function", "arg1", "arg2")
end
```

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

Enable automatic WebSocket reconnection with exponential backoff:

```ruby
client = SurrealDB::Client.new("ws://localhost:8000",
  reconnect: true,
  reconnect_max_retries: 5,
  reconnect_delay: 1.0
)
client.connect
client.signin("user" => "root", "pass" => "root")
client.use("test", "test")

# If the connection drops, the SDK will automatically reconnect,
# replay use/signin/let state, and retry the failed request.
client.query("SELECT * FROM person")
```

## Live Queries

Live queries are supported over WebSocket and embedded connections.

```ruby
SurrealDB.connect("ws://localhost:8000") do |db|
  db.signin("user" => "root", "pass" => "root")
  db.use("test", "test")

  # Start a live query
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
line = SurrealDB::GeometryLine.new(point1, point2)
polygon = SurrealDB::GeometryPolygon.new(exterior_ring)

# Range
range = SurrealDB::Range.new(
  SurrealDB::BoundIncluded.new(1),
  SurrealDB::BoundExcluded.new(10)
)
```

## Error Handling

```ruby
begin
  db.query("INVALID SYNTAX")
rescue SurrealDB::QueryError => e
  puts "Query failed: #{e.message}"
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

## Configuration

```ruby
SurrealDB.configure do |config|
  config.timeout = 60  # seconds (default: 30)
  config.logger = Logger.new($stdout)
end

# Per-connection timeout
client = SurrealDB::Client.new("ws://localhost:8000", timeout: 10)
```

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
