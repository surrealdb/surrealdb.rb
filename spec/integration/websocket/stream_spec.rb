# frozen_string_literal: true

RSpec.describe 'WebSocket query streaming', :integration do
  let(:client) { new_test_client(SurrealHelper::SURREAL_WS_URL) }

  it_behaves_like 'query streaming'

  it 'streams on servers with query_stream (3.1+) and falls back on older ones' do
    client.query_stream('RETURN 1').to_a
    streams = SurrealDB::ServerVersion.parse(client.server_version) >= Gem::Version.new('3.1.0')
    expect(client.connection.supports_streaming?).to eq(streams)
  end

  it 'streams inside a transaction, seeing its uncommitted writes' do
    table = unique_table('stream_tx')
    client.query("DEFINE TABLE #{table} SCHEMALESS")
    tx = client.begin_transaction
    tx.create(SurrealDB::RecordID.new(table, 'a'), { 'n' => 1 })
    rows = tx.query_stream("SELECT n FROM #{table}").select(&:rows?).flat_map(&:values)
    expect(rows).to eq([{ 'n' => 1 }])
    tx.cancel
    expect(client.query("SELECT * FROM #{table}")).to eq([[]])
  end
end
