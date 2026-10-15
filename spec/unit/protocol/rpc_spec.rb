# frozen_string_literal: true

RSpec.describe SurrealDB::Protocol::RPC do
  subject(:rpc) { described_class.new }

  describe '#encode_request' do
    it 'returns an id and encoded bytes' do
      id, bytes = rpc.encode_request('query', ['SELECT * FROM users'])
      expect(id).to be_a(Integer)
      expect(bytes).to be_a(String)
      expect(bytes.encoding).to eq(Encoding::BINARY)
    end

    it 'generates incrementing ids' do
      id1, = rpc.encode_request('ping')
      id2, = rpc.encode_request('ping')
      expect(id2).to eq(id1 + 1)
    end

    it 'encodes a valid CBOR payload' do
      id, bytes = rpc.encode_request('use', %w[test test])
      decoded = CBOR.decode(bytes)
      expect(decoded['id']).to eq(id)
      expect(decoded['method']).to eq('use')
      expect(decoded['params']).to eq(%w[test test])
    end

    it 'omits the session field for the default session' do
      _, bytes = rpc.encode_request('ping')
      expect(CBOR.decode(bytes).keys).to contain_exactly('id', 'method', 'params')
    end

    it 'carries the session id as a uuid in the envelope' do
      session = SurrealDB::Uuid.v4
      _, bytes = rpc.encode_request('query', ['RETURN 1'], session: session)
      field = CBOR.decode(bytes)['session']
      expect(field.tag).to eq(SurrealDB::CBOR::Tags::UUID_BINARY)
      expect(field.value).to eq(session.bytes)
    end

    it 'prepares SurrealDB types in params' do
      _, bytes = rpc.encode_request('select', [SurrealDB::Table.new('users')])
      decoded = CBOR.decode(bytes)
      param = decoded['params'][0]
      expect(param).to be_a(CBOR::Tagged)
      expect(param.tag).to eq(SurrealDB::CBOR::Tags::TABLE)
    end
  end

  describe '#decode_response' do
    it 'decodes a CBOR response' do
      payload = CBOR.encode({ 'id' => 1, 'result' => [{ 'name' => 'John' }] })
      result = rpc.decode_response(payload)
      expect(result['id']).to eq(1)
      expect(result['result']).to eq([{ 'name' => 'John' }])
    end

    it 'resolves SurrealDB tagged types' do
      tagged_table = CBOR::Tagged.new(SurrealDB::CBOR::Tags::TABLE, 'users')
      payload = CBOR.encode({ 'id' => 1, 'result' => tagged_table })
      result = rpc.decode_response(payload)
      expect(result['result']).to be_a(SurrealDB::Table)
    end
  end
end
