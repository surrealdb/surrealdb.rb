# frozen_string_literal: true

RSpec.describe SurrealDB::Connections::ReliableWebSocket do
  let(:inner) do
    instance_double(
      SurrealDB::Connections::WebSocket,
      url: 'ws://localhost:8000',
      connect: nil,
      close: nil,
      connected?: true,
      supports_live_queries?: true,
      attached_sessions: {}
    )
  end
  let(:reliable) { described_class.new(inner, reconnect_max_retries: 2, reconnect_delay: 0.01) }

  describe '#send_request' do
    it 'delegates to the inner connection' do
      allow(inner).to receive(:send_request).and_return('ok')
      expect(reliable.send_request('version')).to eq('ok')
    end

    it 'reconnects and retries on ConnectionError' do
      call_count = 0
      allow(inner).to receive(:send_request) do
        call_count += 1
        raise SurrealDB::ConnectionError, 'disconnected' if call_count == 1

        'ok'
      end
      allow(inner).to receive(:close)
      allow(inner).to receive(:connect)

      result = reliable.send_request('version')
      expect(result).to eq('ok')
      expect(call_count).to eq(2)
    end

    it 'raises after exhausting retries' do
      allow(inner).to receive(:send_request).and_raise(SurrealDB::ConnectionError, 'disconnected')
      allow(inner).to receive(:close)
      allow(inner).to receive(:connect).and_raise(SurrealDB::ConnectionError, 'refused')

      expect { reliable.send_request('version') }.to raise_error(SurrealDB::ConnectionError)
    end
  end

  describe 'state tracking' do
    before do
      allow(inner).to receive(:send_request).and_return(nil)
    end

    it 'replays use after reconnect' do
      reliable.send_request(SurrealDB::Protocol::Methods::USE, %w[ns db])

      call_count = 0
      allow(inner).to receive(:send_request) do |_method, _params|
        call_count += 1
        raise SurrealDB::ConnectionError, 'disconnected' if call_count == 1

        nil
      end
      allow(inner).to receive(:close)
      allow(inner).to receive(:connect)

      reliable.send_request('query', ['SELECT 1'])

      expect(inner).to have_received(:send_request).with('use', %w[ns db], any_args).at_least(:twice)
    end

    it 'replays let variables after reconnect' do
      reliable.send_request(SurrealDB::Protocol::Methods::LET, %w[key value])

      call_count = 0
      allow(inner).to receive(:send_request) do |_method, _params|
        call_count += 1
        raise SurrealDB::ConnectionError, 'disconnected' if call_count == 1

        nil
      end
      allow(inner).to receive(:close)
      allow(inner).to receive(:connect)

      reliable.send_request('query', ['SELECT 1'])

      expect(inner).to have_received(:send_request).with('let', %w[key value], any_args).at_least(:twice)
    end
  end

  describe 'attached sessions' do
    let(:inner) { SurrealDB::Connections::WebSocket.new('ws://localhost:8000') }
    let(:session) { SurrealDB::Uuid.v4 }
    let(:sent) { [] }

    it 'attaches them again with their state before retrying a request made in one' do
      dropped = false
      allow(inner).to receive_messages(connect: nil, close: nil)
      allow(inner).to receive(:execute) do |method, params, session: nil, **|
        sent << [method, params, session]
        if method == 'select' && !dropped
          dropped = true
          raise SurrealDB::ConnectionError, 'disconnected'
        end
      end
      reliable.send_request('attach', [], session: session)
      reliable.send_request('use', %w[ns db], session: session)
      reliable.send_request('let', ['x', 1], session: session)
      sent.clear

      reliable.send_request('select', ['person'], session: session)
      expect(sent).to eq([
                           ['select', ['person'], session],
                           ['attach', [], session], ['use', %w[ns db], session], ['let', ['x', 1], session],
                           ['select', ['person'], session]
                         ])
    end
  end

  describe '#on_notification' do
    it 'delegates and tracks subscriptions' do
      handler = proc {}
      allow(inner).to receive(:on_notification)
      reliable.on_notification('live-id', handler)
      expect(inner).to have_received(:on_notification).with('live-id', handler)
    end
  end

  describe '#remove_notification_handler' do
    it 'delegates and untracks subscriptions' do
      allow(inner).to receive(:on_notification)
      allow(inner).to receive(:remove_notification_handler)
      reliable.on_notification('live-id', proc {})
      reliable.remove_notification_handler('live-id')
      expect(inner).to have_received(:remove_notification_handler).with('live-id')
    end
  end
end
