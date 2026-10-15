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
