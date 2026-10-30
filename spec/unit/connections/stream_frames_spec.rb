# frozen_string_literal: true

RSpec.describe SurrealDB::Connections::StreamFrames do
  let(:frames) { described_class.new(2) }

  it 'holds at most its capacity, making the producer wait for room' do
    expect(frames.push('a', 1)).to be(true)
    expect(frames.push('b', 1)).to be(true)
    expect(frames.push('c', 0.05)).to be(false)
    consumer = Thread.new do
      sleep 0.05
      frames.pop(1)
    end
    expect(frames.push('c', 1)).to be(true)
    expect(consumer.value).to eq('a')
  end

  it 'hands over the frames already buffered, then the error it failed with' do
    frames.push('a', 1)
    frames.fail(SurrealDB::ConnectionError.new('connection closed'))
    expect(frames.pop(1)).to eq('a')
    expect { frames.pop(1) }.to raise_error(SurrealDB::ConnectionError, 'connection closed')
    expect(frames.push('b', 1)).to be(false)
  end

  it 'fails without waiting even when full' do
    2.times { |i| frames.push(i, 1) }
    expect { Timeout.timeout(1) { frames.fail(SurrealDB::ConnectionError.new('closed')) } }.not_to raise_error
  end

  it 'times out a pop when nothing arrives' do
    expect { frames.pop(0.05) }.to raise_error(SurrealDB::TimeoutError, /no stream frame/)
  end
end

RSpec.describe SurrealDB::Connections::WebSocket, '#connect' do
  it 'tries streaming again on a new connection, which may reach another server' do
    connection = described_class.new('ws://localhost:8000')
    connection.streaming_unavailable!
    allow(connection).to receive(:open_socket).and_return(instance_double(TCPSocket, close: nil))
    allow(connection).to receive_messages(send_upgrade: nil, wait_for_open: nil, start_reader: nil)
    connection.connect
    expect(connection).to be_supports_streaming
  end
end

RSpec.describe SurrealDB::Connections::WebSocket, '#deliver_response' do
  let(:connection) { described_class.new('ws://localhost:8000', timeout: 0.1) }
  let(:frames) { SurrealDB::Connections::StreamFrames.new(1) }

  before { connection.instance_variable_get(:@streams)['req'] = frames }

  it 'stops a stream whose caller stopped reading, without holding up the reader for longer' do
    connection.send(:deliver_response, 'req', 'first')
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    connection.send(:deliver_response, 'req', 'second')
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 0.5
    expect(connection.instance_variable_get(:@streams)).to be_empty
    expect(frames.pop(1)).to eq('first')
    expect { frames.pop(1) }.to raise_error(SurrealDB::TimeoutError, /not read for/)
  end
end

RSpec.describe SurrealDB::Connections::WebSocket, '#execute_stream' do
  let(:connection) { described_class.new('ws://localhost:8000', timeout: 2) }

  it 'frees a reader waiting for room before asking the server to stop the stream' do
    connection.instance_variable_set(:@connected, true)
    reader = nil
    allow(connection).to receive(:write_frame) do
      id = connection.instance_variable_get(:@streams).keys.first
      frame = SurrealDB::CBOR::Encoder.encode({ 'id' => id, 'result' => { 'stream' => 'begin' } })
      # More frames than the buffer holds once the caller has taken one: the
      # last push waits for room.
      reader = Thread.new do
        (SurrealDB::Connections::StreamFrames::CAPACITY + 2).times { connection.send(:deliver_response, id, frame) }
      end
      sleep 0.05
    end
    reader_freed = nil
    allow(connection).to receive(:execute) { reader_freed = !reader.join(0.5).nil? }

    connection.send(:execute_stream, 'query_stream', ['SELECT 1']) do
      sleep 0.1 # meanwhile the reader fills the buffer again and waits
      break
    end
    expect(reader_freed).to be(true)
  end

  it 'does not wait for the cancellation past the time the caller had' do
    connection.instance_variable_set(:@connected, true)
    sent = []
    allow(connection).to receive(:write_frame) { |encoded, *| sent << SurrealDB::CBOR::Decoder.decode(encoded) }
    allow(connection).to receive(:execute) { sleep 2 } # a cancellation the server is slow to answer
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect { connection.send(:execute_stream, 'query_stream', ['SELECT 1'], timeout: 0.1) { nil } }
      .to raise_error(SurrealDB::TimeoutError)
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 0.5
    expect(sent.map { |request| request['method'] }).to eq(%w[query_stream query_cancel])
  end

  it 'stops streaming on this connection when the server refuses to stop a stream' do
    connection.instance_variable_set(:@connected, true)
    allow(connection).to receive(:write_frame) do
      id = connection.instance_variable_get(:@streams).keys.first
      frame = SurrealDB::CBOR::Encoder.encode({ 'id' => id, 'result' => { 'stream' => 'begin' } })
      connection.send(:deliver_response, id, frame)
    end
    refused = SurrealDB::NotAllowedError.new('Method not allowed', code: -32_602)
    allow(connection).to receive(:execute).and_raise(refused)
    expect(connection).to be_supports_streaming
    connection.send(:execute_stream, 'query_stream', ['SELECT 1']) { break }
    expect(connection).not_to be_supports_streaming
  end

  it 'keeps streaming when the stream it stops has just ended' do
    connection.instance_variable_set(:@connected, true)
    allow(connection).to receive(:write_frame) do
      id = connection.instance_variable_get(:@streams).keys.first
      frame = SurrealDB::CBOR::Encoder.encode({ 'id' => id, 'result' => { 'stream' => 'begin' } })
      connection.send(:deliver_response, id, frame)
    end
    allow(connection).to receive(:execute).and_raise(
      SurrealDB::ValidationError.new('No streaming query with this request id is in progress', code: -32_603)
    )
    connection.send(:execute_stream, 'query_stream', ['SELECT 1']) { break }
    expect(connection).to be_supports_streaming
  end

  context 'without a timeout' do
    let(:connection) { described_class.new('ws://localhost:8000', timeout: nil) }

    it 'streams, and stops a stream the caller leaves early' do
      connection.instance_variable_set(:@connected, true)
      sent = []
      allow(connection).to receive(:write_frame) do |encoded, deadline, *|
        sent << [SurrealDB::CBOR::Decoder.decode(encoded)['method'], deadline]
        id = connection.instance_variable_get(:@streams).keys.first
        frame = SurrealDB::CBOR::Encoder.encode({ 'id' => id, 'result' => { 'stream' => 'begin' } })
        connection.send(:deliver_response, id, frame)
      end
      allow(connection).to receive(:execute) { |method, *| sent << [method, nil] }
      frames = []
      connection.send(:execute_stream, 'query_stream', ['SELECT 1']) do |frame|
        frames << frame
        break
      end
      expect(frames).to eq([{ 'stream' => 'begin' }])
      expect(sent).to eq([['query_stream', nil], ['query_cancel', nil]])
    end

    it 'still gives up on a caller that stopped reading' do
      stub_const('SurrealDB::Connections::WebSocketStreams::STALLED_READER_TIMEOUT', 0.1)
      frames = SurrealDB::Connections::StreamFrames.new(1)
      connection.instance_variable_get(:@streams)['req'] = frames
      connection.send(:deliver_response, 'req', 'first')
      connection.send(:deliver_response, 'req', 'second')
      expect(frames.pop(1)).to eq('first')
      expect { frames.pop(1) }.to raise_error(SurrealDB::TimeoutError, /not read for 0.1s/)
    end
  end
end
