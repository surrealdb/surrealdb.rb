# frozen_string_literal: true

# Shared CRUD examples that run against both WebSocket and HTTP transports.
#
# SurrealDB returns arrays for record-targeted operations (update, upsert,
# merge, patch, delete on "table:id"). We unwrap single-element arrays
# in the helpers below to keep assertions clean.
RSpec.shared_examples 'CRUD operations' do
  let(:table) { unique_table('crud') }

  after { client.close }

  def unwrap(result)
    result.is_a?(Array) && result.length == 1 ? result[0] : result
  end

  it 'creates and selects a record' do
    created = unwrap(client.create(table, { 'name' => 'Alice', 'age' => 30 }))
    expect(created).to be_a(Hash)
    expect(created['name']).to eq('Alice')

    records = client.select(table)
    expect(records).to be_a(Array)
    expect(records.length).to eq(1)
    expect(records[0]['name']).to eq('Alice')
  end

  it 'creates a record with a specific id' do
    record_id = "#{table}:alice"
    created = unwrap(client.create(record_id, { 'name' => 'Alice' }))
    expect(created).to be_a(Hash)
    expect(created['name']).to eq('Alice')
  end

  it 'inserts multiple records' do
    data = [
      { 'name' => 'Alice' },
      { 'name' => 'Bob' }
    ]
    inserted = client.insert(table, data)
    expect(inserted).to be_a(Array)
    expect(inserted.length).to eq(2)
  end

  it 'updates a record' do
    client.create("#{table}:one", { 'name' => 'Alice', 'age' => 30 })
    updated = unwrap(client.update("#{table}:one", { 'name' => 'Alice', 'age' => 31 }))
    expect(updated).to be_a(Hash)
    expect(updated['age']).to eq(31)
  end

  it 'upserts a record' do
    upserted = unwrap(client.upsert("#{table}:up1", { 'name' => 'Charlie', 'score' => 100 }))
    expect(upserted).to be_a(Hash)
    expect(upserted['name']).to eq('Charlie')
  end

  it 'merges data into a record' do
    client.create("#{table}:m1", { 'name' => 'Alice', 'age' => 30 })
    merged = unwrap(client.merge("#{table}:m1", { 'email' => 'alice@test.com' }))
    expect(merged).to be_a(Hash)
    expect(merged['name']).to eq('Alice')
    expect(merged['email']).to eq('alice@test.com')
  end

  it 'patches a record' do
    client.create("#{table}:p1", { 'name' => 'Alice', 'age' => 30 })
    patched = unwrap(client.patch("#{table}:p1", [
                                    { 'op' => 'replace', 'path' => '/age', 'value' => 31 }
                                  ]))
    expect(patched).to be_a(Hash)
  end

  it 'deletes a record' do
    client.create("#{table}:d1", { 'name' => 'Alice' })
    deleted = unwrap(client.delete("#{table}:d1"))
    expect(deleted).to be_a(Hash)

    # SurrealDB 3.0 raises NotFoundError on select from empty/nonexistent tables
    remaining = begin
      client.select(table)
    rescue SurrealDB::NotFoundError
      []
    end
    expect(remaining).to be_empty
  end

  it 'deletes all records from a table' do
    client.query("DEFINE TABLE #{table} SCHEMALESS")
    client.create("#{table}:d2", { 'name' => 'Alice' })
    client.create("#{table}:d3", { 'name' => 'Bob' })
    client.delete(table)

    remaining = begin
      client.select(table)
    rescue SurrealDB::NotFoundError
      []
    end
    expect(remaining).to be_empty
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

  it 'returns durations the server sends in short compact form' do
    result = client.query('RETURN [0s, 5s, 1500ms]').first['result']
    expect(result).to eq([
                           SurrealDB::Duration.new(0, 0),
                           SurrealDB::Duration.new(5, 0),
                           SurrealDB::Duration.new(1, 500_000_000)
                         ])
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
