# frozen_string_literal: true

RSpec.describe SurrealDB::Client do
  describe 'URL scheme dispatch' do
    it 'creates a reconnecting WebSocket connection for ws://' do
      client = described_class.new('ws://localhost:8000')
      expect(client.connection).to be_a(SurrealDB::Connections::ReliableWebSocket)
      expect(client.connection.inner).to be_a(SurrealDB::Connections::WebSocket)
    end

    it 'creates a reconnecting WebSocket connection for wss://' do
      client = described_class.new('wss://localhost:8000')
      expect(client.connection).to be_a(SurrealDB::Connections::ReliableWebSocket)
    end

    it 'creates a plain WebSocket connection with reconnect: false' do
      client = described_class.new('ws://localhost:8000', reconnect: false)
      expect(client.connection).to be_a(SurrealDB::Connections::WebSocket)
    end

    it 'creates an HTTP connection for http://' do
      client = described_class.new('http://localhost:8000')
      expect(client.connection).to be_a(SurrealDB::Connections::HTTP)
    end

    it 'creates an HTTP connection for https://' do
      client = described_class.new('https://localhost:8000')
      expect(client.connection).to be_a(SurrealDB::Connections::HTTP)
    end

    it 'raises ArgumentError for unsupported schemes' do
      expect { described_class.new('ftp://localhost') }.to raise_error(ArgumentError, /unsupported URL scheme/)
    end
  end

  describe 'live query gating' do
    let(:client) { described_class.new('http://localhost:8000') }

    it 'raises UnsupportedError for #live on HTTP' do
      expect { client.live('table') }.to raise_error(SurrealDB::UnsupportedError, /live queries/)
    end

    it 'raises UnsupportedError for #subscribe on HTTP' do
      expect { client.subscribe('uuid') {} }.to raise_error(SurrealDB::UnsupportedError) # rubocop:disable Lint/EmptyBlock
    end

    it 'raises UnsupportedError for #kill on HTTP' do
      expect { client.kill('uuid') }.to raise_error(SurrealDB::UnsupportedError)
    end
  end

  describe 'session/transaction gating' do
    let(:client) { described_class.new('http://localhost:8000') }

    it 'raises UnsupportedError for #begin_transaction on HTTP' do
      expect { client.begin_transaction }.to raise_error(SurrealDB::UnsupportedError, /transactions/)
    end

    it 'raises UnsupportedError for #commit and #cancel by id on HTTP, sending nothing' do
      allow(client.connection).to receive(:send_request)
      expect { client.commit(SurrealDB::Uuid.v4) }.to raise_error(SurrealDB::UnsupportedError, /transactions/)
      expect { client.cancel(SurrealDB::Uuid.v4) }.to raise_error(SurrealDB::UnsupportedError, /transactions/)
      expect(client.connection).not_to have_received(:send_request)
    end
  end

  describe '#create data parameter' do
    let(:connection) { instance_double(SurrealDB::Connections::WebSocket, supports_live_queries?: true) }
    let(:client) { described_class.new('ws://localhost:8000') }

    before do
      client.instance_variable_set(:@connection, connection)
    end

    it 'omits data when nil' do
      allow(connection).to receive(:send_request)
      client.create('table')
      expect(connection).to have_received(:send_request).with('create', [SurrealDB::Table.new('table')])
    end

    it 'includes data when present' do
      allow(connection).to receive(:send_request)
      client.create('table', { 'name' => 'Alice' })
      expect(connection).to have_received(:send_request)
        .with('create', [SurrealDB::Table.new('table'), { 'name' => 'Alice' }])
    end

    it 'includes data even when falsy (false)' do
      allow(connection).to receive(:send_request)
      client.create('table', false)
      expect(connection).to have_received(:send_request).with('create', [SurrealDB::Table.new('table'), false])
    end
  end

  describe 'record and table targets' do
    let(:connection) { instance_double(SurrealDB::Connections::WebSocket, supports_live_queries?: true) }
    let(:client) { described_class.new('ws://localhost:8000') }
    let(:rid) { SurrealDB::RecordID.new('person', 'alice') }

    before do
      client.instance_variable_set(:@connection, connection)
      allow(connection).to receive(:send_request)
    end

    it 'sends a RecordID as a typed value, not a string' do
      client.select(rid)
      expect(connection).to have_received(:send_request).with('select', [rid])
    end

    it 'sends a StringRecordID as a typed value' do
      srid = SurrealDB::StringRecordID.new('person:alice')
      client.delete(srid)
      expect(connection).to have_received(:send_request).with('delete', [srid])
    end

    it 'sends a plain string as a table' do
      client.select('person')
      expect(connection).to have_received(:send_request).with('select', [SurrealDB::Table.new('person')])
    end

    %i[select create update upsert merge patch delete].each do |method|
      it "refuses to guess that a \"table:id\" string is a record id in ##{method}" do
        args = %i[select delete].include?(method) ? [] : [{}]
        expect { client.public_send(method, 'person:alice', *args) }
          .to raise_error(ArgumentError, /RecordID\.parse/)
        expect(connection).not_to have_received(:send_request)
      end
    end

    it 'sends relate endpoints as typed record ids' do
      bob = SurrealDB::RecordID.new('person', 'bob')
      client.relate(rid, 'knows', bob)
      expect(connection).to have_received(:send_request)
        .with('relate', [rid, SurrealDB::Table.new('knows'), bob])
    end

    it 'refuses string relate endpoints' do
      expect { client.relate('person:alice', 'knows', rid) }.to raise_error(ArgumentError, /RecordID/)
    end
  end

  describe 'sessions' do
    let(:connection) do
      instance_double(SurrealDB::Connections::WebSocket, supports_live_queries?: true, supports_sessions?: true,
                                                         supports_session_listing?: true)
    end
    let(:client) { described_class.new('ws://localhost:8000') }

    before do
      client.instance_variable_set(:@connection, connection)
      allow(connection).to receive(:send_request)
    end

    it 'attaches with a fresh client-generated id in the envelope' do
      session = client.new_session
      expect(session.id).to be_a(SurrealDB::Uuid)
      expect(connection).to have_received(:send_request).with('attach', [], session: session.id)
    end

    it 'runs requests made through the session in that session' do
      session = client.new_session
      session.select('person')
      expect(connection).to have_received(:send_request)
        .with('select', [SurrealDB::Table.new('person')], session: session.id)
    end

    it 'detaches by id and refuses further use' do
      session = client.new_session
      session.close
      expect(connection).to have_received(:send_request).with('detach', [], session: session.id)
      expect { session.query('RETURN 1') }.to raise_error(SurrealDB::SessionError)
    end

    it 'closes a Session detached through the client' do
      session = client.new_session
      client.detach(session)
      expect(session).to be_closed
      expect { session.select('person') }.to raise_error(SurrealDB::SessionError)
      session.close
      expect(connection).to have_received(:send_request).with('detach', [], session: session.id).once
    end

    it 'refuses to list sessions over HTTP, where the server rejects it' do
      http = described_class.new('http://localhost:8000')
      allow(http.connection).to receive(:send_request)
      expect { http.sessions }.to raise_error(SurrealDB::UnsupportedError, /listing sessions/)
      expect(http.connection).not_to have_received(:send_request)
    end

    it 'detaches when the block form returns, even on error' do
      captured = nil
      expect do
        client.new_session do |s|
          captured = s
          raise 'boom'
        end
      end.to raise_error('boom')
      expect(captured).to be_closed
    end
  end

  describe 'transactions' do
    let(:connection) do
      instance_double(SurrealDB::Connections::WebSocket, supports_transactions?: true, supports_sessions?: true)
    end
    let(:client) { described_class.new('ws://localhost:8000') }
    let(:txn_id) { SurrealDB::Uuid.v4 }

    before do
      client.instance_variable_set(:@connection, connection)
      allow(connection).to receive(:send_request).and_return(nil)
      allow(connection).to receive(:send_request).with('begin', []).and_return(txn_id)
    end

    it 'is lost when its connection fails, and refuses further requests locally' do
      allow(connection).to receive(:send_request).with('query', any_args)
                                                 .and_raise(SurrealDB::ConnectionError, 'connection lost')
      tx = client.begin_transaction
      expect { tx.query('UPDATE person SET n += 1') }.to raise_error(SurrealDB::ConnectionError)
      expect(tx).to be_lost
      expect { tx.query('RETURN 1') }.to raise_error(SurrealDB::TransactionError, /lost/)
      expect { tx.commit }.to raise_error(SurrealDB::TransactionError, /lost/)
    end

    it 'begins a transaction and runs its requests with the txn id in the envelope' do
      tx = client.begin_transaction
      expect(tx.id).to eq(txn_id)
      tx.query('CREATE person')
      expect(connection).to have_received(:send_request)
        .with('query', ['CREATE person'], session: nil, txn: txn_id)
    end

    it 'commits and cancels by sending the txn id as the param' do
      client.begin_transaction.commit
      expect(connection).to have_received(:send_request).with('commit', [txn_id], session: nil)
      client.begin_transaction.cancel
      expect(connection).to have_received(:send_request).with('cancel', [txn_id], session: nil)
    end

    it 'is lost when a request through it times out, as it may still be running' do
      allow(connection).to receive(:send_request).with('query', any_args).and_raise(SurrealDB::TimeoutError, 'slow')
      tx = client.begin_transaction
      expect { tx.query('UPDATE person SET n += 1') }.to raise_error(SurrealDB::TimeoutError)
      expect(tx).not_to be_open
      expect { tx.query('RETURN 1') }.to raise_error(SurrealDB::TransactionError, /lost/)
    end

    it 'stays open when a request through it timed out before it was sent' do
      not_sent = SurrealDB::TimeoutError.new('timed out renewing the access token', sent: false)
      allow(connection).to receive(:send_request).with('query', any_args).and_raise(not_sent)
      tx = client.begin_transaction
      expect { tx.query('UPDATE person SET n += 1') }.to raise_error(SurrealDB::TimeoutError)
      expect(tx).to be_open
      tx.commit
      expect(connection).to have_received(:send_request).with('commit', [txn_id], session: nil)
    end

    it 'refuses requests after the transaction is finished' do
      tx = client.begin_transaction
      tx.commit
      expect { tx.query('RETURN 1') }.to raise_error(SurrealDB::TransactionError)
      expect { tx.commit }.to raise_error(SurrealDB::TransactionError)
    end

    it 'commits when the block returns and returns its value' do
      expect(client.begin_transaction { |_tx| :done }).to eq(:done)
      expect(connection).to have_received(:send_request).with('commit', [txn_id], session: nil)
    end

    it 'cancels when the block raises' do
      expect { client.begin_transaction { |_tx| raise 'boom' } }.to raise_error('boom')
      expect(connection).to have_received(:send_request).with('cancel', [txn_id], session: nil)
      expect(connection).not_to have_received(:send_request).with('commit', anything, anything)
    end

    it 'cancels when the block leaves early with break, return or throw' do
      client.begin_transaction { |_tx| break }
      catch(:out) { client.begin_transaction { |_tx| throw :out } }
      leave = ->(c) { c.begin_transaction { |_tx| return :early } }
      expect(leave.call(client)).to eq(:early)

      expect(connection).to have_received(:send_request).with('cancel', [txn_id], session: nil).exactly(3).times
      expect(connection).not_to have_received(:send_request).with('commit', anything, anything)
    end

    it 'runs a session transaction in that session' do
      session = client.new_session
      allow(connection).to receive(:send_request).with('begin', [], session: session.id).and_return(txn_id)
      tx = session.begin_transaction
      tx.select('person')
      tx.commit
      expect(connection).to have_received(:send_request)
        .with('select', [SurrealDB::Table.new('person')], session: session.id, txn: txn_id)
      expect(connection).to have_received(:send_request).with('commit', [txn_id], session: session.id)
    end

    it 'marks open transactions cancelled when the session is reset' do
      open = client.begin_transaction
      done = client.begin_transaction
      done.commit
      client.reset
      expect(open).to be_cancelled
      expect(done).to be_committed
      expect { open.query('RETURN 1') }.to raise_error(SurrealDB::TransactionError)
    end
  end

  describe '#reset' do
    let(:client) { described_class.new('ws://localhost:8000', reconnect: false) }
    let(:live_id) { SurrealDB::Uuid.v4 }

    before do
      allow(client.connection).to receive(:send_request).and_return(nil)
      allow(client.connection).to receive(:send_request).with('live', anything).and_return(live_id)
    end

    it 'removes the handlers of the live queries the server killed' do
      client.subscribe(client.live('person')) { nil }
      client.reset
      expect(client.connection.instance_variable_get(:@live_handlers)).to be_empty
    end
  end

  describe '#send_rpc' do
    let(:connection) { instance_double(SurrealDB::Connections::WebSocket, supports_live_queries?: true) }
    let(:client) { described_class.new('ws://localhost:8000') }

    before do
      client.instance_variable_set(:@connection, connection)
      allow(connection).to receive(:send_request).and_return('ok')
    end

    it 'forwards arbitrary method calls' do
      result = client.send_rpc('custom_method', [1, 2, 3])
      expect(connection).to have_received(:send_request).with('custom_method', [1, 2, 3])
      expect(result).to eq('ok')
    end
  end

  describe '#run version parameter' do
    let(:connection) { instance_double(SurrealDB::Connections::WebSocket, supports_live_queries?: true) }
    let(:client) { described_class.new('ws://localhost:8000') }

    before do
      client.instance_variable_set(:@connection, connection)
      allow(connection).to receive(:send_request)
    end

    it 'passes nil version by default' do
      client.run('fn::test', 'arg1')
      expect(connection).to have_received(:send_request).with('run', ['fn::test', nil, ['arg1']])
    end

    it 'passes explicit version when given' do
      client.run('fn::test', 'arg1', version: '1.0.0')
      expect(connection).to have_received(:send_request).with('run', ['fn::test', '1.0.0', ['arg1']])
    end
  end
end

RSpec.describe SurrealDB::Client, '#healthy?' do
  it 'is false when the server cannot be reached' do
    port = TCPServer.open('127.0.0.1', 0) { |server| server.addr[1] } # a port nobody listens on
    client = described_class.new("http://127.0.0.1:#{port}", timeout: 2)
    expect(client.healthy?).to be(false)
    expect { client.health }.to raise_error(SurrealDB::ConnectionError)
  end

  it 'is false when something other than an HTTP server answers' do
    server = TCPServer.new('127.0.0.1', 0)
    answering = Thread.new do
      loop do
        socket = server.accept
        socket.readpartial(4096)
        socket.write("SSH-2.0-OpenSSH_9.6\r\n\r\n")
        socket.close
      end
    rescue IOError, SystemCallError
      nil
    end
    client = described_class.new("http://127.0.0.1:#{server.addr[1]}", timeout: 2)
    expect(client.healthy?).to be(false)
    expect { client.health }.to raise_error(SurrealDB::ProtocolError, /malformed/)
    expect { client.connect }.to raise_error(SurrealDB::ProtocolError, /malformed/) # the version check
  ensure
    server&.close
    answering&.kill
  end
end

RSpec.describe SurrealDB::Client, '#use' do
  let(:client) { described_class.new('http://localhost:8000') }

  before { allow(client.connection).to receive(:send_request).and_return(nil) }

  it 'clears the database with the namespace, which the server requires' do
    client.use(namespace: nil)
    expect(client.connection).to have_received(:send_request).with('use', [nil, nil])
  end

  it 'refuses a database without a namespace' do
    expect { client.use(nil, 'prod') }.to raise_error(ArgumentError, /without a namespace/)
    expect(client.connection).not_to have_received(:send_request)
  end
end

RSpec.describe SurrealDB::Client, '#with_timeout' do
  let(:connection) do
    instance_double(SurrealDB::Connections::WebSocket, supports_transactions?: true, supports_sessions?: true)
  end
  let(:client) { described_class.new('ws://localhost:8000') }

  before do
    client.instance_variable_set(:@connection, connection)
    allow(connection).to receive(:send_request).and_return([])
  end

  it 'passes a call timeout to the connection, and none otherwise' do
    client.query('RETURN 1', timeout: 2)
    expect(connection).to have_received(:send_request).with('query', ['RETURN 1'], timeout: 2)
    client.query('RETURN 2')
    expect(connection).to have_received(:send_request).with('query', ['RETURN 2'])
  end

  it 'still takes query variables as keywords' do
    client.query('RETURN $min', min: 1)
    client.query_raw('RETURN $a + $b', { 'a' => 1 }, b: 2, timeout: 4)
    expect(connection).to have_received(:send_request).with('query', ['RETURN $min', { min: 1 }])
    expect(connection).to have_received(:send_request)
      .with('query', ['RETURN $a + $b', { 'a' => 1, b: 2 }], timeout: 4)
  end

  it 'applies with_timeout to the block, innermost first, and restores it after' do
    client.with_timeout(5) do
      client.select('a')
      client.with_timeout(1) { client.select('b') }
      client.select('c')
      client.query('RETURN 3', timeout: 9) # an explicit timeout wins
    end
    client.select('d')

    expect(connection).to have_received(:send_request).with('select', [SurrealDB::Table.new('a')], timeout: 5)
    expect(connection).to have_received(:send_request).with('select', [SurrealDB::Table.new('b')], timeout: 1)
    expect(connection).to have_received(:send_request).with('select', [SurrealDB::Table.new('c')], timeout: 5)
    expect(connection).to have_received(:send_request).with('query', ['RETURN 3'], timeout: 9)
    expect(connection).to have_received(:send_request).with('select', [SurrealDB::Table.new('d')])
  end

  it 'covers sessions and transactions on the same connection' do
    allow(connection).to receive(:send_request).with('begin', [], any_args).and_return(SurrealDB::Uuid.v4)
    session = client.new_session
    tx = client.begin_transaction
    client.with_timeout(3) do
      session.select('s')
      tx.select('t')
    end
    expect(connection).to have_received(:send_request)
      .with('select', [SurrealDB::Table.new('s')], session: session.id, timeout: 3)
    expect(connection).to have_received(:send_request)
      .with('select', [SurrealDB::Table.new('t')], session: nil, txn: tx.id, timeout: 3)
  end

  it 'does not leak to other connections' do
    other = described_class.new('ws://localhost:8000')
    other_connection = instance_double(SurrealDB::Connections::WebSocket)
    other.instance_variable_set(:@connection, other_connection)
    allow(other_connection).to receive(:send_request).and_return([])
    client.with_timeout(3) { other.select('x') }
    expect(other_connection).to have_received(:send_request).with('select', [SurrealDB::Table.new('x')])
  end

  context 'with requests the client sends straight to the connection' do
    # Records the timeout each request reaches the transport with.
    let(:connection) do
      Class.new(SurrealDB::Connections::Base) do
        attr_reader :timeouts

        def initialize(url)
          super
          @timeouts = {}
          @connected = true
        end

        protected

        def execute(method, _params, timeout: nil, **)
          @timeouts[method] = timeout
          method == 'begin' ? SurrealDB::Uuid.v4 : nil
        end
      end.new('ws://localhost:8000')
    end

    before { allow(connection).to receive(:send_request).and_call_original }

    it 'applies with_timeout to them too: version, sessions and the commit of a transaction' do
      client.with_timeout(0.3) do
        client.version
        client.new_session.close
        client.transaction { |tx| tx.query_raw('RETURN 1') }
      end
      about = a_value_between(0.15, 0.301)
      expect(connection.timeouts).to include('version' => about, 'attach' => about, 'detach' => about,
                                             'begin' => about, 'query' => about, 'commit' => about)
    end

    it 'applies with_timeout to the HTTP routes too: health, import and export' do
      endpoint = instance_double(SurrealDB::Connections::HTTPEndpoint)
      allow(endpoint).to receive(:request) do |_verb, path, timeout: nil, **|
        connection.timeouts[path] = timeout
        Net::HTTPOK.new('1.1', '200', 'OK')
      end
      allow(connection).to receive(:http_endpoint).and_return(endpoint)
      client.with_timeout(0.3) do
        client.health
        connection.http_request(:post, '/import', body: '')
      end
      expect(connection.timeouts).to include('/health' => a_value_between(0.15, 0.301),
                                             '/import' => a_value_between(0.15, 0.301))
    end
  end

  it 'refuses a timeout that is not a positive number' do
    expect { client.with_timeout(0) { nil } }.to raise_error(ArgumentError)
    expect { client.with_timeout('5') { nil } }.to raise_error(ArgumentError)
  end
end

RSpec.describe SurrealDB::Client, '#import' do
  let(:connection) { instance_double(SurrealDB::Connections::WebSocket) }
  let(:client) { described_class.new('ws://localhost:8000') }

  before { client.instance_variable_set(:@connection, connection) }

  def answer(code, body)
    klass = Net::HTTPResponse::CODE_TO_OBJ.fetch(code.to_s)
    klass.new('1.1', code.to_s, '').tap do |response|
      response.instance_variable_set(:@body, body)
      response.instance_variable_set(:@read, true)
    end
  end

  it 'raises when a successful import answers with something it cannot read' do
    allow(connection).to receive(:http_request).and_return(answer(200, 'not cbor'))
    expect { client.import("OPTION IMPORT;\nCREATE x;") }.to raise_error(SurrealDB::ProtocolError, /import's result/)
  end

  it 'raises when a successful import answers with something other than statement results' do
    [nil, 'ok', { 'status' => 'OK' }, [1], [{}], [{ 'status' => 'UNKNOWN' }]].each do |result|
      allow(connection).to receive(:http_request).and_return(answer(200, SurrealDB::CBOR::Encoder.encode(result)))
      expect { client.import("OPTION IMPORT;\nCREATE x;") }.to raise_error(SurrealDB::ProtocolError, /not a list/)
    end
  end

  it 'is fine with a successful import that reports no failures' do
    allow(connection).to receive(:http_request).and_return(answer(200, SurrealDB::CBOR::Encoder.encode([])))
    expect(client.import("OPTION IMPORT;\nCREATE x;")).to be_nil
  end
end

RSpec.describe SurrealDB::Client, '#fork_session' do
  let(:connection) do
    Class.new(SurrealDB::Connections::Base) do
      def initialize(url)
        super
        @connected = true
      end

      protected

      def execute(method, *, **)
        { 'access' => 'a1', 'refresh' => 'r1' } if method == 'signin'
      end
    end.new('ws://localhost:8000')
  end
  let(:client) { described_class.new('ws://localhost:8000') }

  before { client.instance_variable_set(:@connection, connection) }

  it 'gives the fork what it needs to renew its token: the refresh token and the sign-in' do
    client.signin({ 'user' => 'u', 'pass' => 'p' })
    fork = client.fork_session
    state = connection.session_state(fork.id)
    expect(state.tokens).to eq({ 'access' => 'a1', 'refresh' => 'r1' })
    expect(state.signin).to eq(['signin', [{ 'user' => 'u', 'pass' => 'p' }]])
  end
end

RSpec.describe SurrealDB::Connections::HTTP, '#close' do
  let(:connection) { described_class.new('http://localhost:8000') }
  let(:first) { SurrealDB::Uuid.v4 }
  let(:second) { SurrealDB::Uuid.v4 }

  before do
    connection.instance_variable_set(:@connected, true)
    allow(connection).to receive(:execute).and_return(nil)
    connection.send_request('attach', [], session: first)
    connection.send_request('attach', [], session: second)
  end

  it 'detaches the sessions still attached, which the server would otherwise keep' do
    connection.close
    expect(connection).to have_received(:execute).with('detach', [], hash_including(session: first))
    expect(connection).to have_received(:execute).with('detach', [], hash_including(session: second))
    expect(connection).not_to be_connected
  end

  it 'stops trying once the server cannot be reached' do
    allow(connection).to receive(:execute).with('detach', any_args).and_raise(SurrealDB::ConnectionError, 'down')
    connection.close
    expect(connection).to have_received(:execute).with('detach', any_args).once
    expect(connection).not_to be_connected
  end
end
