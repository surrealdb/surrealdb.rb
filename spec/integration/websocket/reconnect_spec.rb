# frozen_string_literal: true

RSpec.describe 'WebSocket reconnection', :integration do
  let(:proxy) { TCPProxy.new(SurrealHelper::SURREAL_WS_URL) }
  let!(:client) do
    SurrealDB::Client.new(proxy.url, reconnect_delay: 0.05, reconnect_max_retries: 5, timeout: 5).tap do |c|
      c.connect
      c.signin({ 'user' => SurrealHelper::SURREAL_USER, 'pass' => SurrealHelper::SURREAL_PASS })
      c.use(SurrealHelper::SURREAL_NS, SurrealHelper::SURREAL_DB)
    end
  end
  let(:table) { unique_table('reconnect') }

  after do
    client.close
    proxy.close
  end

  def wait_until(seconds = 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    until yield
      raise 'timed out waiting' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.02
    end
  end

  def drop_and_wait_for_reconnect
    before = proxy.connections
    proxy.drop_all
    wait_until { proxy.connections > before && client.connected? }
  end

  it 'reconnects by default and restores namespace, database, credentials and variables' do
    expect(client.connection).to be_a(SurrealDB::Connections::ReliableWebSocket)
    client.set('marker', 42)
    drop_and_wait_for_reconnect

    result = client.query_raw('RETURN [session::ns(), session::db(), $marker]')[0].result
    expect(result).to eq([SurrealHelper::SURREAL_NS, SurrealHelper::SURREAL_DB, 42])
    expect(client.query_raw("DEFINE TABLE #{table}")[0]).to be_ok # still signed in as root
  end

  it 'reconnects in the background, without waiting for a request to fail' do
    proxy.drop_all
    wait_until { proxy.connections >= 2 && client.connected? }
    expect(client.query_raw('RETURN 1')[0].result).to eq(1)
  end

  it 'restores attached sessions with their own state' do
    session = client.fork_session
    session.use(SurrealHelper::SURREAL_NS, 'reconnect_other')
    session.set('who', 'session')
    drop_and_wait_for_reconnect

    expect(session.query_raw('RETURN [session::db(), $who]')[0].result).to eq(%w[reconnect_other session])
    expect(client.query_raw('RETURN session::db()')[0].result).to eq(SurrealHelper::SURREAL_DB)
  end

  it 're-issues live queries and keeps delivering under the original id' do
    client.query("DEFINE TABLE #{table} SCHEMALESS")
    live_id = client.live(table)
    notifications = Queue.new
    client.subscribe(live_id) { |n| notifications << n }

    drop_and_wait_for_reconnect
    client.create(SurrealDB::RecordID.new(table, 'after'), { 'n' => 1 })

    notification = Timeout.timeout(5) { notifications.pop }
    expect(notification['id']).to eq(live_id)
    expect(notification['action'].to_s.downcase).to eq('create')
    expect(notification['result']['id']).to eq(SurrealDB::RecordID.new(table, 'after'))

    client.kill(live_id) # kills the re-issued query, by the id the caller holds
    client.create(SurrealDB::RecordID.new(table, 'killed'), {})
    sleep 0.3
    expect(notifications).to be_empty
  end

  it 'does not repeat a write that was in flight when the connection dropped' do
    client.query("DEFINE TABLE #{table} SCHEMALESS")
    writer = Thread.new do
      client.query("SLEEP 500ms; CREATE #{table} SET n = 1")
    rescue SurrealDB::Error => e
      e
    end
    sleep 0.2
    proxy.drop_all
    error = writer.value

    expect(error).to be_a(SurrealDB::RequestInterruptedError)
    wait_until { client.connected? }
    sleep 0.6 # let the server finish the statement it already received
    expect(client.select(table).length).to be <= 1
  end

  it 'repeats a read that was in flight when the connection dropped' do
    client.query("DEFINE TABLE #{table} SCHEMALESS")
    client.create(SurrealDB::RecordID.new(table, 'r'), {})
    proxy.drop_all
    expect(client.select(table).map { |r| r['id'] }).to eq([SurrealDB::RecordID.new(table, 'r')])
  end

  it 'gives up a transaction rather than replaying it' do
    tx = client.begin_transaction
    tx.query("CREATE #{table}:t")
    proxy.drop_all
    expect { tx.query("CREATE #{table}:u") }.to raise_error(SurrealDB::ConnectionError)
  end

  it 'does not reconnect after close' do
    client.close
    count = proxy.connections
    sleep 0.2
    expect(proxy.connections).to eq(count)
    expect { client.query('RETURN 1') }.to raise_error(SurrealDB::ConnectionError)
  end
end
