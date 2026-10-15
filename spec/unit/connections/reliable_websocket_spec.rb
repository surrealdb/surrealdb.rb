# frozen_string_literal: true

RSpec.describe SurrealDB::Connections::ReliableWebSocket do
  # Stands in for Connections::WebSocket: records every request and lets a
  # test script failures with `fail_next`.
  let(:fake_class) do
    Class.new(SurrealDB::Connections::Base) do
      attr_reader :calls, :connects, :handlers, :last_timeout

      def initialize(url)
        super
        @calls = []
        @connects = 0
        @failures = []
        @handlers = {}
        @live_counter = 0
      end

      def connect
        @connects += 1
        @connected = true
      end

      def close
        @connected = false
      end

      def on_disconnect(&block)
        @on_disconnect = block
      end

      # Queues an error for the next request; NotConnectedError means the
      # request never left, anything else that it was in flight.
      def fail_next(error)
        @failures << error
      end

      def on_notification(id, handler)
        @handlers[id] = handler
      end

      def remove_notification_handler(id)
        @handlers.delete(id)
      end

      protected

      def execute(method, params, session: nil, txn: nil, timeout: nil)
        @calls << [method, params, session, txn]
        @last_timeout = timeout
        unless @failures.empty?
          @connected = false
          raise @failures.shift
        end

        case method
        when 'live' then SurrealDB::Uuid.parse(format('00000000-0000-4000-8000-%012d', @live_counter += 1))
        when 'begin' then SurrealDB::Uuid.parse('11111111-1111-4111-8111-111111111111')
        when 'signin' then 'token-1'
        when 'signup' then { 'access' => 'a1', 'refresh' => 'r1' }
        when 'refresh' then { 'access' => 'a2', 'refresh' => 'r2' }
        else 'ok'
        end
      end
    end
  end

  let(:inner) { fake_class.new('ws://localhost:8000') }
  let(:reliable) do
    described_class.new(inner, reconnect_max_retries: 2, reconnect_delay: 0.01).tap(&:connect)
  end

  def methods_sent
    inner.calls.map(&:first)
  end

  describe '#send_request' do
    it 'delegates to the inner connection' do
      expect(reliable.send_request('version')).to eq('ok')
      expect(inner.calls).to eq([['version', [], nil, nil]])
    end

    it 'reconnects and sends a request that never left, whatever it is' do
      inner.fail_next(SurrealDB::NotConnectedError.new('not connected'))
      expect(reliable.send_request('query', ['CREATE x'])).to eq('ok')
      expect(inner.connects).to eq(2)
      expect(methods_sent.count('query')).to eq(2)
    end

    it 'repeats a read that was in flight' do
      inner.fail_next(SurrealDB::ConnectionError.new('connection closed'))
      expect(reliable.send_request('select', ['person'])).to eq('ok')
      expect(methods_sent.count('select')).to eq(2)
    end

    it 'does not repeat a query that was in flight' do
      inner.fail_next(SurrealDB::ConnectionError.new('connection closed'))
      expect { reliable.send_request('query', ['CREATE x']) }
        .to raise_error(SurrealDB::RequestInterruptedError, /may already have run/)
      expect(methods_sent.count('query')).to eq(1)
      expect(reliable).to be_connected # but it did reconnect
    end

    it 'does not repeat a write that was in flight' do
      %w[create update upsert merge patch delete insert relate run].each do |method|
        inner.fail_next(SurrealDB::ConnectionError.new('connection closed'))
        expect { reliable.send_request(method, ['person']) }.to raise_error(SurrealDB::RequestInterruptedError)
      end
    end

    it 'raises after exhausting reconnection attempts' do
      reliable
      inner.fail_next(SurrealDB::NotConnectedError.new('not connected'))
      allow(inner).to receive(:connect).and_raise(SurrealDB::ConnectionError, 'refused')
      expect { reliable.send_request('version') }.to raise_error(SurrealDB::ConnectionError, /after 2 attempts/)
    end

    context 'when closed while a reconnect is under way' do
      let(:reliable) do
        described_class.new(inner, reconnect_max_retries: 3, reconnect_delay: 0.2).tap(&:connect)
      end

      def close_soon
        Thread.new do
          sleep 0.05
          reliable.close
        end
      end

      it 'stops retrying' do
        reliable
        attempts = 0
        allow(inner).to receive(:connect) do
          attempts += 1
          raise SurrealDB::ConnectionError, 'refused'
        end
        inner.fail_next(SurrealDB::NotConnectedError.new('not connected'))
        closer = close_soon
        expect { reliable.send_request('version') }
          .to raise_error(SurrealDB::NotConnectedError, /closed while reconnecting/)
        closer.join
        expect(attempts).to eq(1)
        expect(reliable).not_to be_connected
      end

      it 'drops a socket that opened after the close' do
        reliable
        allow(inner).to receive(:connect).and_wrap_original do |original|
          sleep 0.15
          original.call
        end
        inner.fail_next(SurrealDB::NotConnectedError.new('not connected'))
        closer = close_soon
        expect { reliable.send_request('version') }.to raise_error(SurrealDB::NotConnectedError)
        closer.join
        expect(inner).not_to be_connected
      end
    end

    it 'counts waiting for a reconnect against the call timeout, and leaves the reconnect running' do
      reliable
      allow(inner).to receive(:connect).and_wrap_original do |original|
        sleep 0.3
        original.call
      end
      inner.fail_next(SurrealDB::NotConnectedError.new('not connected'))
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect { reliable.send_request('version', timeout: 0.1) }
        .to raise_error(SurrealDB::TimeoutError, /'version' timed out waiting for the connection/)
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 0.25
      expect(reliable.send_request('version', timeout: 1)).to eq('ok') # waits for the same reconnect
      expect(inner.last_timeout).to be < 0.9
      expect(inner.connects).to eq(2)
    end

    it 'does not reconnect after close' do
      reliable.close
      inner.fail_next(SurrealDB::NotConnectedError.new('not connected'))
      expect { reliable.send_request('version') }.to raise_error(SurrealDB::NotConnectedError)
      expect(inner.connects).to eq(1)
    end
  end

  describe 'transactions' do
    let(:txn) { reliable.send_request('begin') }

    it 'never sends a transaction request on a new connection' do
      txn
      inner.fail_next(SurrealDB::NotConnectedError.new('not connected'))
      expect { reliable.send_request('select', ['person'], txn: txn) }
        .to raise_error(SurrealDB::RequestInterruptedError, /ended transaction/)
      expect { reliable.send_request('commit', [txn]) }.to raise_error(SurrealDB::RequestInterruptedError)
      expect(inner.calls.count { |call| call[3] }).to eq(1)
      expect(methods_sent).not_to include('commit')
      expect(reliable.send_request('commit', [txn])).to eq('ok') # forgotten once ended
    end

    it 'marks a Transaction lost, so it is not used on the new connection' do
      tx = SurrealDB::Transaction.new(reliable, txn)
      inner.fail_next(SurrealDB::NotConnectedError.new('not connected'))
      expect { tx.commit }.to raise_error(SurrealDB::RequestInterruptedError)
      expect(tx).to be_lost
      expect { tx.query('RETURN 1') }.to raise_error(SurrealDB::TransactionError, /lost/)
      expect(inner.calls.count { |call| call[3] }).to eq(0)
    end

    it 'does not repeat a read inside a transaction' do
      txn
      inner.fail_next(SurrealDB::ConnectionError.new('connection closed'))
      expect { reliable.send_request('select', ['person'], txn: txn) }
        .to raise_error(SurrealDB::RequestInterruptedError)
    end
  end

  describe 'state restored after a reconnect' do
    def drop
      inner.fail_next(SurrealDB::NotConnectedError.new('not connected'))
      reliable.send_request('version')
    end

    it 'replays use and variables, in that order' do
      reliable.send_request('use', %w[ns db])
      reliable.send_request('let', %w[key value])
      inner.calls.clear
      drop
      expect(inner.calls).to eq([
                                  ['version', [], nil, nil],
                                  ['use', %w[ns db], nil, nil],
                                  ['let', %w[key value], nil, nil],
                                  ['version', [], nil, nil]
                                ])
    end

    it 're-authenticates with the token' do
      reliable.send_request('signin', [{ 'user' => 'root', 'pass' => 'root' }])
      inner.calls.clear
      drop
      expect(inner.calls).to include(['authenticate', ['token-1'], nil, nil])
      expect(methods_sent).not_to include('signin')
    end

    it 'signs in again when the token is no longer accepted' do
      reliable.send_request('signin', [{ 'user' => 'root', 'pass' => 'root' }])
      allow(inner).to receive(:send_request).and_call_original
      allow(inner).to receive(:send_request).with('authenticate', anything, any_args)
                                            .and_raise(SurrealDB::ServerError, 'token expired')
      inner.calls.clear
      drop
      expect(inner.calls).to include(['signin', [{ 'user' => 'root', 'pass' => 'root' }], nil, nil])
    end

    it 'uses the refresh token when the stored token is refused' do
      reliable.send_request('signup', [{ 'ac' => 'user' }])
      allow(inner).to receive(:send_request).and_call_original
      allow(inner).to receive(:send_request).with('authenticate', anything, any_args)
                                            .and_raise(SurrealDB::ServerError, 'token expired')
      inner.calls.clear
      drop
      expect(inner.calls).to include(['refresh', [{ 'access' => 'a1', 'refresh' => 'r1' }], nil, nil])
      expect(methods_sent).not_to include('signup')
      expect(reliable.session_state.tokens).to eq({ 'access' => 'a2', 'refresh' => 'r2' })
    end

    it 'restores the rest of the state when a token that cannot be renewed is refused' do
      reliable.send_request('signup', [{ 'ac' => 'user' }])
      reliable.send_request('use', %w[ns db])
      allow(inner).to receive(:send_request).and_call_original
      %w[authenticate refresh].each do |method|
        allow(inner).to receive(:send_request).with(method, anything, any_args)
                                              .and_raise(SurrealDB::ServerError, 'token expired')
      end
      inner.calls.clear
      drop
      expect(methods_sent).to eq(%w[version invalidate use version])
      expect(inner.session_state).not_to be_authenticated
    end

    it 'does not repeat a request signed out when its credentials could not be restored' do
      reliable.send_request('signup', [{ 'ac' => 'user' }])
      allow(inner).to receive(:send_request).and_call_original
      %w[authenticate refresh].each do |method|
        allow(inner).to receive(:send_request).with(method, anything, any_args)
                                              .and_raise(SurrealDB::ServerError, 'token expired')
      end
      inner.calls.clear
      inner.fail_next(SurrealDB::ConnectionError.new('connection closed'))
      expect { reliable.send_request('select', ['person']) }
        .to raise_error(SurrealDB::AuthenticationError, /signed out; 'select' was not sent/)
      expect(methods_sent).to eq(%w[select invalidate])
      expect(reliable.send_request('select', ['person'])).to eq('ok') # made knowing it is signed out
    end

    it 'restores the other sessions when one cannot be restored' do
      broken = SurrealDB::Uuid.v4
      fine = SurrealDB::Uuid.v4
      [broken, fine].each { |id| reliable.send_request('attach', [], session: id) }
      reliable.send_request('use', %w[ns gone], session: broken)
      reliable.send_request('use', %w[ns ok], session: fine)
      allow(inner).to receive(:send_request).and_call_original
      allow(inner).to receive(:send_request).with('use', %w[ns gone], any_args)
                                            .and_raise(SurrealDB::ServerError, 'no such database')
      inner.calls.clear
      drop
      expect(inner.calls).to include(['use', %w[ns ok], fine, nil])
      expect(reliable).to be_connected
    end

    it 'restores the attached sessions and live queries when the default session cannot be restored' do
      session = SurrealDB::Uuid.v4
      reliable.send_request('use', %w[ns gone])
      reliable.send_request('attach', [], session: session)
      reliable.send_request('use', %w[ns ok], session: session)
      reliable.send_request('live', ['person'])
      allow(inner).to receive(:send_request).and_call_original
      allow(inner).to receive(:send_request).with('use', %w[ns gone], any_args)
                                            .and_raise(SurrealDB::ServerError, 'no such database')
      inner.calls.clear
      drop
      expect(methods_sent).to include('attach', 'live')
      expect(inner.calls).to include(['use', %w[ns ok], session, nil])
    end

    it 'does not start a live query again when the connection dropped under its kill' do
      original = reliable.send_request('live', ['person'])
      reliable.on_notification(original, proc {})
      inner.calls.clear
      inner.fail_next(SurrealDB::ConnectionError.new('connection closed'))
      expect(reliable.send_request('kill', [original])).to be_nil
      expect(methods_sent).to eq(%w[kill])
      expect(inner.handlers).to be_empty
      expect(inner.connects).to eq(2)
    end

    it 'never repeats a signup' do
      reliable.send_request('signup', [{ 'access' => 'user', 'email' => 'a@b.c' }])
      inner.calls.clear
      drop
      expect(methods_sent).not_to include('signup')
    end

    it 'attaches every session again and restores its own state' do
      session = SurrealDB::Uuid.v4
      reliable.send_request('attach', [], session: session)
      reliable.send_request('use', %w[ns other], session: session)
      inner.calls.clear
      drop
      expect(inner.calls).to include(['attach', [], session, nil], ['use', %w[ns other], session, nil])
    end

    it 're-issues live queries and delivers under the id the caller holds' do
      original = reliable.send_request('live', ['person'])
      received = []
      reliable.on_notification(original.to_s, ->(n) { received << n })
      drop

      fresh = inner.calls.reverse.find { |call| call[0] == 'live' }
      expect(inner.calls.count { |call| call[0] == 'live' }).to eq(2)
      new_id = SurrealDB::Uuid.parse('00000000-0000-4000-8000-000000000002')
      expect(fresh[1]).to eq(['person'])
      inner.handlers[new_id.to_s].call({ 'id' => new_id, 'action' => 'CREATE' })
      expect(received).to eq([{ 'id' => original, 'action' => 'CREATE' }])

      reliable.send_request('kill', [original])
      expect(inner.calls.last).to eq(['kill', [new_id], nil, nil])
    end
  end

  describe '#http_request' do
    it 'reconnects first, as renewing the token needs the WebSocket' do
      endpoint = instance_double(SurrealDB::Connections::HTTPEndpoint, request: :response)
      allow(inner).to receive(:http_endpoint).and_return(endpoint)
      reliable
      inner.close
      expect(reliable.http_request(:post, '/import', body: 'x')).to eq(:response)
      expect(inner.connects).to eq(2)
    end
  end

  describe 'reset' do
    it 'forgets the live queries the server killed with the session' do
      reliable.send_request('live', ['person'])
      reliable.send_request('reset')
      inner.calls.clear
      inner.fail_next(SurrealDB::NotConnectedError.new('not connected'))
      reliable.send_request('version')
      expect(methods_sent).not_to include('live')
    end

    it 'removes the handlers of the live queries it killed, also after a reconnect' do
      original = reliable.send_request('live', ['person'])
      other = SurrealDB::Uuid.v4
      reliable.send_request('attach', [], session: other)
      kept = reliable.send_request('live', ['person'], session: other)
      [original, kept].each { |id| reliable.on_notification(id, proc {}) }
      inner.fail_next(SurrealDB::NotConnectedError.new('not connected'))
      reliable.send_request('version') # reconnects; the live queries get new ids
      reliable.send_request('reset')
      expect(inner.handlers.size).to eq(1)
    end

    it 'is repeated when it was in flight' do
      inner.fail_next(SurrealDB::ConnectionError.new('connection closed'))
      expect(reliable.send_request('reset')).to eq('ok')
      expect(methods_sent.count('reset')).to eq(2)
    end
  end

  describe 'detach' do
    it 'forgets the live queries of the detached session, and their handlers' do
      session = SurrealDB::Uuid.v4
      reliable.send_request('attach', [], session: session)
      live = reliable.send_request('live', ['person'], session: session)
      kept = reliable.send_request('live', ['person'])
      [live, kept].each { |id| reliable.on_notification(id, proc {}) }
      reliable.send_request('detach', [], session: session)
      expect(inner.handlers.keys).to eq([kept.to_s])
      inner.calls.clear
      inner.fail_next(SurrealDB::NotConnectedError.new('not connected'))
      reliable.send_request('version')
      expect(inner.calls.select { |call| call[0] == 'live' }.map { |call| call[2] }).to eq([nil])
    end
  end

  describe '#on_notification' do
    it 'registers a handler on the inner connection' do
      reliable.on_notification('live-id', proc {})
      expect(inner.handlers.keys).to eq(['live-id'])
    end
  end

  describe '#remove_notification_handler' do
    it 'removes the handler from the inner connection' do
      reliable.on_notification('live-id', proc {})
      reliable.remove_notification_handler('live-id')
      expect(inner.handlers).to be_empty
    end
  end
end
