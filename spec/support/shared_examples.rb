# frozen_string_literal: true

# Shared CRUD examples that run against both WebSocket and HTTP transports.
#
# SurrealDB returns arrays for record-targeted operations (update, upsert,
# merge, patch, delete on "table:id"). We unwrap single-element arrays
# in the helpers below to keep assertions clean.
RSpec.shared_examples 'CRUD operations' do
  let(:table) { unique_table('crud') }

  after { client.close }

  def rid(key)
    SurrealDB::RecordID.new(table, key)
  end

  def unwrap(result)
    result.is_a?(Array) && result.length == 1 ? result[0] : result
  end

  it 'creates and selects a record' do
    created = unwrap(client.create(table, { 'name' => 'Alice', 'age' => 30 }))
    expect(created['id']).to be_a(SurrealDB::RecordID)
    expect(created['id'].table).to eq(table)
    expect(created['name']).to eq('Alice')

    records = client.select(table)
    expect(records.map { |r| r['id'] }).to eq([created['id']])
  end

  it 'creates a record with a specific id in the right table' do
    created = unwrap(client.create(rid('alice'), { 'name' => 'Alice' }))
    expect(created['id']).to eq(rid('alice'))
    expect(created['name']).to eq('Alice')

    # Regression: record ids used to be sent as strings, so this created a
    # table literally named "<table>:alice".
    tables = db_tables(client)
    expect(tables).to include(table)
    expect(tables).not_to include("#{table}:alice")
  end

  it 'selects a single record by id' do
    client.create(rid('alice'), { 'name' => 'Alice' })
    client.create(rid('bob'), { 'name' => 'Bob' })
    selected = unwrap(client.select(rid('alice')))
    expect(selected).to eq({ 'id' => rid('alice'), 'name' => 'Alice' })
  end

  it 'lets the server parse a StringRecordID' do
    client.create(rid('alice'), { 'name' => 'Alice' })
    selected = unwrap(client.select(SurrealDB::StringRecordID.new("#{table}:alice")))
    expect(selected['id']).to eq(rid('alice'))
  end

  it 'round-trips integer and array record keys' do
    created = unwrap(client.create(rid(42), { 'n' => 1 }))
    expect(created['id']).to eq(rid(42))
    created = unwrap(client.create(rid(['London', 7]), { 'n' => 2 }))
    expect(created['id']).to eq(rid(['London', 7]))
    expect(unwrap(client.select(rid(['London', 7])))['n']).to eq(2)
  end

  it 'refuses a "table:id" string instead of guessing' do
    expect { client.select("#{table}:alice") }.to raise_error(ArgumentError, /RecordID/)
  end

  it 'inserts multiple records' do
    inserted = client.insert(table, [{ 'name' => 'Alice' }, { 'name' => 'Bob' }])
    expect(inserted.map { |r| r['name'] }).to contain_exactly('Alice', 'Bob')
    expect(inserted.map { |r| r['id'].table }.uniq).to eq([table])
    expect(client.select(table).length).to eq(2)
  end

  it 'updates a record' do
    client.create(rid('one'), { 'name' => 'Alice', 'age' => 30 })
    updated = unwrap(client.update(rid('one'), { 'name' => 'Alice', 'age' => 31 }))
    expect(updated).to eq({ 'id' => rid('one'), 'name' => 'Alice', 'age' => 31 })
    expect(unwrap(client.select(rid('one')))['age']).to eq(31)
  end

  it 'upserts a record' do
    upserted = unwrap(client.upsert(rid('up1'), { 'name' => 'Charlie', 'score' => 100 }))
    expect(upserted).to eq({ 'id' => rid('up1'), 'name' => 'Charlie', 'score' => 100 })
    upserted = unwrap(client.upsert(rid('up1'), { 'name' => 'Charlie', 'score' => 101 }))
    expect(upserted['score']).to eq(101)
    expect(client.select(table).length).to eq(1)
  end

  it 'merges data into a record' do
    client.create(rid('m1'), { 'name' => 'Alice', 'age' => 30 })
    merged = unwrap(client.merge(rid('m1'), { 'email' => 'alice@test.com' }))
    expect(merged).to eq({ 'id' => rid('m1'), 'name' => 'Alice', 'age' => 30, 'email' => 'alice@test.com' })
  end

  it 'patches a record' do
    client.create(rid('p1'), { 'name' => 'Alice', 'age' => 30 })
    client.patch(rid('p1'), [{ 'op' => 'replace', 'path' => '/age', 'value' => 31 }])
    expect(unwrap(client.select(rid('p1')))['age']).to eq(31)
  end

  it 'deletes a record' do
    client.create(rid('d1'), { 'name' => 'Alice' })
    client.create(rid('d2'), { 'name' => 'Bob' })
    deleted = unwrap(client.delete(rid('d1')))
    expect(deleted).to eq({ 'id' => rid('d1'), 'name' => 'Alice' })
    expect(client.select(table).map { |r| r['id'] }).to eq([rid('d2')])
  end

  it 'deletes all records from a table' do
    client.create(rid('d2'), { 'name' => 'Alice' })
    client.create(rid('d3'), { 'name' => 'Bob' })
    client.delete(table)
    remaining = begin
      client.select(table)
    rescue SurrealDB::NotFoundError # SurrealDB 3.0 may answer this for an emptied table
      []
    end
    expect(remaining).to eq([])
  end

  it 'relates two records' do
    alice = rid('alice')
    bob = rid('bob')
    client.create(alice, {})
    client.create(bob, {})
    edge_table = unique_table('knows')
    edge = unwrap(client.relate(alice, edge_table, bob, { 'since' => 2020 }))
    expect(edge['in']).to eq(alice)
    expect(edge['out']).to eq(bob)
    expect(edge['id'].table).to eq(edge_table)
    expect(edge['since']).to eq(2020)
  end
end

RSpec.shared_examples 'query operations' do
  let(:table) { unique_table('query') }

  after { client.close }

  it 'executes a raw query' do
    client.create(table, { 'name' => 'Alice', 'age' => 30 })
    results = client.query("SELECT * FROM #{table}")
    expect(results).to be_a(Array)
  end

  it 'executes a parameterized query' do
    client.create(table, { 'name' => 'Alice', 'age' => 30 })
    client.create(table, { 'name' => 'Bob', 'age' => 25 })
    results = client.query('SELECT * FROM type::table($table) WHERE age > $min_age', {
                             'table' => table,
                             'min_age' => 28
                           })
    expect(results).to be_a(Array)
  end

  it 'handles multi-statement queries' do
    results = client.query("CREATE #{table}:a SET name = 'Alice'; CREATE #{table}:b SET name = 'Bob';")
    expect(results).to be_a(Array)
  end
end

RSpec.shared_examples 'auth operations' do
  after { client.close }

  it 'returns version info' do
    version = client.version
    expect(version).to be_a(String)
    expect(version).to include('surrealdb')
  end

  it 'can invalidate and re-signin' do
    client.invalidate
    client.signin({ 'user' => SurrealHelper::SURREAL_USER, 'pass' => SurrealHelper::SURREAL_PASS })
    client.use(SurrealHelper::SURREAL_NS, SurrealHelper::SURREAL_DB)
    expect(client.version).to be_a(String)
  end
end

RSpec.shared_examples 'value round-trips' do
  let(:table) { unique_table('types') }

  after { client.close }

  def value_of(sql, vars = {})
    client.query_raw(sql, vars).last.result
  end

  it 'decodes server UUIDs as Uuid, not String' do
    expect(value_of('RETURN rand::uuid::v7()')).to be_a(SurrealDB::Uuid)
  end

  it 'sends Uuid as a uuid, not a string' do
    uuid = SurrealDB::Uuid.v4
    expect(value_of('RETURN [type::is_uuid($u), type::is_string($u), $u]', { 'u' => uuid })).to eq([true, false, uuid])
  end

  it 'round-trips a uuid-keyed record id' do
    rid = SurrealDB::RecordID.new(table, SurrealDB::Uuid.v7)
    created = client.create(rid, { 'n' => 1 })
    created = created[0] if created.is_a?(Array)
    expect(created['id']).to eq(rid)
    selected = client.select(rid)
    selected = selected[0] if selected.is_a?(Array)
    expect(selected).to eq({ 'id' => rid, 'n' => 1 })
  end

  it 'round-trips sets' do
    expect(value_of('RETURN <set>[3, 1, 1]')).to eq(Set[1, 3])
    expect(value_of('RETURN $s', { 's' => Set['a', 'b'] })).to eq(Set['a', 'b'])
  end

  it 'round-trips file pointers' do
    file = SurrealDB::FileRef.new('bucket', '/some/key.txt')
    expect(value_of('RETURN $f', { 'f' => file })).to eq(file)
  end

  it 'round-trips datetimes with nanosecond precision, before and after 1970' do
    [Time.utc(2024, 2, 29, 12, 0, 0, Rational(123_456_789, 1000)), Time.utc(1969, 7, 20, 20, 17, 40.5r)].each do |time|
      back = value_of('RETURN $t', { 't' => time })
      expect(back).to eq(time)
      expect(value_of('RETURN type::is_datetime($t)', { 't' => time })).to be(true)
    end
  end
end

RSpec.shared_examples 'sessions' do
  after { client.close }

  def where_am_i(target)
    target.query_raw('RETURN [session::ns(), session::db()]')[0].result
  end

  # Whether the session is signed in as a user allowed to define things.
  def can_define?(target)
    target.query_raw("DEFINE TABLE OVERWRITE #{unique_table('auth')}")[0].ok?
  end

  def signed_in_session
    session = client.new_session
    session.signin({ 'user' => SurrealHelper::SURREAL_USER, 'pass' => SurrealHelper::SURREAL_PASS })
    session.use(SurrealHelper::SURREAL_NS, SurrealHelper::SURREAL_DB)
    session
  end

  it 'runs a new session independently of the default session' do
    session = client.new_session
    expect(session.id).to be_a(SurrealDB::Uuid)
    expect(where_am_i(session)).to eq([SurrealDB::NONE, SurrealDB::NONE])

    session.signin({ 'user' => SurrealHelper::SURREAL_USER, 'pass' => SurrealHelper::SURREAL_PASS })
    session.use('sess_ns', 'sess_db')
    expect(where_am_i(session)).to eq(%w[sess_ns sess_db])
    expect(where_am_i(client)).to eq([SurrealHelper::SURREAL_NS, SurrealHelper::SURREAL_DB])
  ensure
    session&.close
  end

  it 'keeps variables per session' do
    one = signed_in_session
    two = signed_in_session
    one.set('who', 'one')
    two.set('who', 'two')
    expect(one.query_raw('RETURN $who')[0].result).to eq('one')
    expect(two.query_raw('RETURN $who')[0].result).to eq('two')
    two.unset('who')
    expect(two.query_raw('RETURN $who')[0].result).to eq(SurrealDB::NONE)
  ensure
    one&.close
    two&.close
  end

  it 'keeps credentials per session' do
    session = client.new_session
    session.use(SurrealHelper::SURREAL_NS, SurrealHelper::SURREAL_DB)
    expect(can_define?(session)).to be(false)
    expect(can_define?(client)).to be(true)
  ensure
    session&.close
  end

  it 'detaches a session' do
    session = client.new_session
    id = session.id
    session.close
    expect(session).to be_closed
    expect { session.query('RETURN 1') }.to raise_error(SurrealDB::SessionError)
    expect { client.connection.send_request('query', ['RETURN 1'], session: id) }
      .to raise_error(SurrealDB::NotFoundError, /Session not found/)
  end

  it 'detaches when the block returns' do
    id = client.new_session(&:id)
    expect { client.connection.send_request('query', ['RETURN 1'], session: id) }
      .to raise_error(SurrealDB::NotFoundError)
  end

  it 'forks a session with its namespace, database, variables and credentials' do
    source = signed_in_session
    source.set('greeting', 'hello')
    source.fork_session do |fork|
      expect(fork.id).not_to eq(source.id)
      expect(where_am_i(fork)).to eq([SurrealHelper::SURREAL_NS, SurrealHelper::SURREAL_DB])
      expect(fork.query_raw('RETURN $greeting')[0].result).to eq('hello')
      expect(can_define?(fork)).to be(true)

      fork.set('greeting', 'changed')
      expect(source.query_raw('RETURN $greeting')[0].result).to eq('hello')
    end
  ensure
    source&.close
  end

  it 'forks the default session' do
    client.fork_session do |fork|
      expect(where_am_i(fork)).to eq([SurrealHelper::SURREAL_NS, SurrealHelper::SURREAL_DB])
      expect(can_define?(fork)).to be(true)
    end
  end
end

RSpec.shared_examples 'import and export' do
  let(:table) { unique_table('impexp') }

  after { client.close }

  def rid(key)
    SurrealDB::RecordID.new(table, key)
  end

  it 'imports SurrealQL through the HTTP route' do
    client.import("OPTION IMPORT; DEFINE TABLE #{table} SCHEMALESS; " \
                  "CREATE #{table}:one SET n = 1; CREATE #{table}:two SET n = 2;")
    expect(client.select(table).map { |r| r['n'] }.sort).to eq([1, 2])
  end

  it 'imports from an IO' do
    client.import(StringIO.new("OPTION IMPORT; CREATE #{table}:io SET n = 3;"))
    expect(client.select(rid('io'))).to include('n' => 3)
  end

  it 'passes on the server refusing content without OPTION IMPORT' do
    expect { client.import("CREATE #{table}:x") }.to raise_error(SurrealDB::ServerError, /OPTION IMPORT/)
  end

  it 'reports failed statements, keeping the ones that ran' do
    sql = "OPTION IMPORT; CREATE #{table}:ok SET n = 1; THROW 'import broke'; CREATE #{table}:after SET n = 2;"
    expect { client.import(sql) }.to raise_error(SurrealDB::ImportError) { |e|
      expect(e.count).to eq(1)
      expect(e.failures.first).to be_a(SurrealDB::ServerError)
      expect(e.failures.first.message).to include('import broke')
    }
    expect(client.select(rid('ok'))).to include('n' => 1)
  end

  it 'refuses an import without credentials' do
    anonymous = SurrealDB::Client.new(client.connection.url)
    anonymous.connect
    anonymous.use(SurrealHelper::SURREAL_NS, SurrealHelper::SURREAL_DB)
    expect { anonymous.import("OPTION IMPORT; CREATE #{table}:nope") }.to raise_error(SurrealDB::NotAllowedError)
  ensure
    anonymous&.close
  end

  it 'exports the database as SurrealQL' do
    client.create(rid('exported'), { 'name' => 'Alice' })
    sql = client.export
    expect(sql).to include("DEFINE TABLE #{table}")
    expect(sql).to include('Alice')
    expect(sql.encoding).to eq(Encoding::UTF_8)
  end

  it 'exports with options' do
    other = unique_table('other')
    client.create(rid('a'), { 'name' => 'Alice' })
    client.create(SurrealDB::RecordID.new(other, 'b'), { 'name' => 'Bob' })
    sql = client.export(tables: [table], records: false)
    expect(sql).to include("DEFINE TABLE #{table}")
    expect(sql).not_to include(other)
    expect(sql).not_to include('Alice')
  end

  it 'streams an export to a block' do
    client.create(rid('streamed'), { 'name' => 'Streamy' })
    chunks = []
    expect(client.export { |chunk| chunks << chunk }).to be_nil
    expect(chunks.join).to include('Streamy')
  end

  it 'passes on an error the export block raises, not as a connection error' do
    expect { client.export { |_chunk| raise Errno::ENOSPC } }.to raise_error(Errno::ENOSPC)
  end

  it 'refuses import and export once the client is closed' do
    client.close
    expect { client.export }.to raise_error(SurrealDB::ConnectionError, /not connected/)
    expect { client.import("OPTION IMPORT;\nCREATE x;") }.to raise_error(SurrealDB::ConnectionError, /not connected/)
  end

  it 'round-trips an export through an import' do
    client.create(rid('rt'), { 'name' => 'Round', 'tags' => %w[a b] })
    sql = client.export(tables: [table])
    client.query("REMOVE TABLE #{table}")
    client.import(sql)
    expect(client.select(rid('rt'))).to include('name' => 'Round', 'tags' => %w[a b])
  end
end

RSpec.shared_examples 'session variables' do
  after { client.close }

  def value_of(sql, vars = {})
    client.query_raw(sql, vars).last.result
  end

  it 'keeps a variable set with set/let for later queries' do
    client.set('greeting', 'hello')
    client.let('count', 3)
    expect(value_of('RETURN $greeting')).to eq('hello')
    expect(value_of('RETURN [$greeting, $count]')).to eq(['hello', 3])
  end

  it 'lets query variables override session variables for that query only' do
    client.set('who', 'session')
    expect(value_of('RETURN $who', { 'who' => 'query' })).to eq('query')
    expect(value_of('RETURN $who')).to eq('session')
  end

  it 'forgets a variable after unset' do
    client.set('temp', 1)
    client.unset('temp')
    expect(value_of('RETURN $temp')).to eq(SurrealDB::NONE)
  end

  it 'refuses a name the server protects, as it does over every transport' do
    expect { client.set('auth', 1) }.to raise_error(SurrealDB::ServerError)
    expect(value_of('RETURN $auth')).not_to eq(1)
  end

  it 'keeps the value as it was set, whatever the caller does to its object later' do
    tags = ['a']
    client.set('tags', tags)
    tags << 'b'
    expect(value_of('RETURN $tags')).to eq(['a'])
  end
end
