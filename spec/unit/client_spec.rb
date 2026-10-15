# frozen_string_literal: true

RSpec.describe SurrealDB::Client do
  describe 'URL scheme dispatch' do
    it 'creates a WebSocket connection for ws://' do
      client = described_class.new('ws://localhost:8000')
      expect(client.connection).to be_a(SurrealDB::Connections::WebSocket)
    end

    it 'creates a WebSocket connection for wss://' do
      client = described_class.new('wss://localhost:8000')
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
    [nil, 'ok', { 'status' => 'OK' }, [1]].each do |result|
      allow(connection).to receive(:http_request).and_return(answer(200, SurrealDB::CBOR::Encoder.encode(result)))
      expect { client.import("OPTION IMPORT;\nCREATE x;") }.to raise_error(SurrealDB::ProtocolError, /not a list/)
    end
  end

  it 'is fine with a successful import that reports no failures' do
    allow(connection).to receive(:http_request).and_return(answer(200, SurrealDB::CBOR::Encoder.encode([])))
    expect(client.import("OPTION IMPORT;\nCREATE x;")).to be_nil
  end
end
