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
      instance_double(SurrealDB::Connections::WebSocket, supports_live_queries?: true, supports_sessions?: true)
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
