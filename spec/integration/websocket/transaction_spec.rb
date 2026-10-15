# frozen_string_literal: true

RSpec.describe 'WebSocket transactions', :integration do
  let(:client) { new_test_client(SurrealHelper::SURREAL_WS_URL) }
  let(:table) { unique_table('txn') }

  before { client.query("DEFINE TABLE #{table} SCHEMALESS") }
  after { client.close }

  def rid(key)
    SurrealDB::RecordID.new(table, key)
  end

  def keys_in(target)
    target.select(table).map { |r| r['id'].id }.sort
  end

  it 'keeps writes inside the transaction until commit' do
    tx = client.begin_transaction
    expect(tx.id).to be_a(SurrealDB::Uuid)
    tx.create(rid('a'), { 'n' => 1 })
    tx.query("CREATE #{table}:b")

    expect(keys_in(tx)).to eq(%w[a b])
    expect(keys_in(client)).to eq([])

    tx.commit
    expect(tx).to be_committed
    expect(keys_in(client)).to eq(%w[a b])
  end

  it 'discards writes on cancel' do
    client.create(rid('kept'), {})
    tx = client.begin_transaction
    tx.create(rid('dropped'), {})
    tx.delete(rid('kept'))
    tx.cancel
    expect(tx).to be_cancelled
    expect(keys_in(client)).to eq(%w[kept])
  end

  it 'commits a block and cancels it on error' do
    client.begin_transaction { |tx| tx.create(rid('one'), {}) }
    expect do
      client.begin_transaction do |tx|
        tx.create(rid('two'), {})
        raise ArgumentError, 'nope'
      end
    end.to raise_error(ArgumentError)
    expect(keys_in(client)).to eq(%w[one])
  end

  it 'rejects requests after the transaction finished' do
    tx = client.begin_transaction
    tx.commit
    expect { tx.select(table) }.to raise_error(SurrealDB::TransactionError)
  end

  it 'reports an unknown transaction from the server' do
    expect { client.commit(SurrealDB::Uuid.v4) }.to raise_error(SurrealDB::ServerError, /Transaction not found/)
  end

  it 'runs a transaction inside an attached session' do
    client.fork_session do |session|
      session.begin_transaction do |tx|
        tx.create(rid('s'), {})
        expect(keys_in(session)).to eq([])
      end
      expect(keys_in(client)).to eq(%w[s])
    end
  end
end
