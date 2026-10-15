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
    expect(client.select(table)).to eq([])
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
