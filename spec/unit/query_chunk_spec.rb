# frozen_string_literal: true

RSpec.describe SurrealDB::QueryChunk do
  describe '.from_frame' do
    it 'reads rows, value and finished frames' do
      rows = described_class.from_frame({ 'stream' => 'rows', 'index' => 0, 'values' => [{ 'n' => 1 }] })
      expect([rows.kind, rows.index, rows.values]).to eq([:rows, 0, [{ 'n' => 1 }]])

      value = described_class.from_frame({ 'stream' => 'value', 'index' => 1, 'value' => 7 })
      expect([value.kind, value.value]).to eq([:value, 7])

      finished = described_class.from_frame({ 'stream' => 'finished', 'index' => 1, 'time' => '1ms',
                                              'error' => SurrealDB::NONE })
      expect([finished.kind, finished.time, finished.error]).to eq([:finished, '1ms', nil])
    end

    it 'turns a statement error into the error class for its kind' do
      finished = described_class.from_frame({ 'stream' => 'finished', 'index' => 2,
                                              'error' => { 'kind' => 'Thrown', 'message' => 'boom' } })
      expect(finished.error).to be_a(SurrealDB::ThrownError)
      expect(finished).to be_error
    end

    it 'skips the begin and end frames' do
      expect(described_class.from_frame({ 'stream' => 'begin', 'statements' => 2 })).to be_nil
      expect(described_class.from_frame({ 'stream' => 'end', 'results' => 2 })).to be_nil
    end
  end

  describe '.implied_by' do
    def finished(single)
      described_class.from_frame({ 'stream' => 'finished', 'index' => 3, 'single' => single })
    end

    it 'stands for the empty list a statement with no rows frame returned' do
      chunk = described_class.implied_by(finished(false))
      expect([chunk.index, chunk.kind, chunk.values]).to eq([3, :rows, []])
    end

    it 'stands for NONE when the statement returns one value but sent no value frame' do
      chunk = described_class.implied_by(finished(true))
      expect([chunk.kind, chunk.value]).to eq([:value, SurrealDB::NONE])
    end
  end

  describe '.from_results' do
    it 'stands in for a stream from buffered results' do
      results = [
        SurrealDB::QueryResult.new(status: 'OK', time: '1ms', result: [{ 'n' => 1 }]),
        SurrealDB::QueryResult.new(status: 'OK', time: '2ms', result: 7),
        SurrealDB::QueryResult.new(status: 'ERR', time: '3ms', error: 'boom', kind: 'Thrown')
      ]
      chunks = described_class.from_results(results)
      expect(chunks.map { |c| [c.index, c.kind] })
        .to eq([[0, :rows], [0, :finished], [1, :value], [1, :finished], [2, :finished]])
      expect(chunks.last.error).to be_a(SurrealDB::ThrownError)
    end
  end
end

RSpec.describe SurrealDB::Client, '#query_stream' do
  let(:connection) { instance_double(SurrealDB::Connections::WebSocket) }
  let(:client) { described_class.new('ws://localhost:8000') }

  before { client.instance_variable_set(:@connection, connection) }

  it 'falls back to a buffered query when the server has no query_stream, and remembers' do
    supported = true
    allow(connection).to receive(:supports_streaming?) { supported }
    allow(connection).to receive(:streaming_unavailable!) { supported = false }
    allow(connection).to receive(:stream_request)
      .and_raise(SurrealDB::NotFoundError.new('Method not found', code: -32_601))
    allow(connection).to receive(:send_request).with('query', ['RETURN 1'])
                                               .and_return([{ 'status' => 'OK', 'time' => '1ms', 'result' => 1 }])

    expect(client.query_stream('RETURN 1').map(&:kind)).to eq(%i[value finished])
    client.query_stream('RETURN 1').to_a
    expect(connection).to have_received(:stream_request).once
  end

  it 'does not fall back when the stream had started' do
    allow(connection).to receive(:supports_streaming?).and_return(true)
    allow(connection).to receive(:stream_request) do |*, &block|
      block.call({ 'stream' => 'begin', 'statements' => 1 })
      raise SurrealDB::NotFoundError.new('Method not found', code: -32_601)
    end
    expect { client.query_stream('RETURN 1').to_a }.to raise_error(SurrealDB::NotFoundError)
  end

  it 'raises the error a stopped stream ends with' do
    allow(connection).to receive(:supports_streaming?).and_return(true)
    allow(connection).to receive(:stream_request) do |*, &block|
      block.call({ 'stream' => 'end', 'error' => { 'kind' => 'Query', 'message' => 'cancelled' } })
    end
    expect { client.query_stream('RETURN 1').to_a }.to raise_error(SurrealDB::QueryError, /cancelled/)
  end
end
