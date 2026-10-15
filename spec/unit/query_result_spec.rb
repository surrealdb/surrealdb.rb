# frozen_string_literal: true

RSpec.describe SurrealDB::QueryResult do
  describe '.from_response' do
    it 'parses a successful statement' do
      qr = described_class.from_response({
                                           'status' => 'OK',
                                           'time' => '1.234ms',
                                           'result' => [{ 'id' => 'user:1', 'name' => 'Alice' }]
                                         })
      expect(qr).to be_ok
      expect(qr).not_to be_error
      expect(qr.status).to eq('OK')
      expect(qr.time).to eq('1.234ms')
      expect(qr.result).to eq([{ 'id' => 'user:1', 'name' => 'Alice' }])
      expect(qr.error).to be_nil
    end

    it 'parses an error statement' do
      qr = described_class.from_response({
                                           'status' => 'ERR',
                                           'time' => '0.5ms',
                                           'result' => nil,
                                           'error' => 'table not found'
                                         })
      expect(qr).to be_error
      expect(qr).not_to be_ok
      expect(qr.error).to eq('table not found')
    end

    it 'reads a failed statement the way the server sends it' do
      qr = described_class.from_response({
                                           'status' => 'ERR', 'time' => '1ms',
                                           'result' => "The table 'x' does not exist",
                                           'kind' => 'NotFound',
                                           'details' => { 'kind' => 'Table', 'details' => { 'name' => 'x' } }
                                         })
      expect(qr.error).to eq("The table 'x' does not exist")
      expect(qr.result).to be_nil
      error = qr.to_error
      expect(error).to be_a(SurrealDB::NotFoundError)
      expect(error.message).to eq("The table 'x' does not exist")
      expect(error.details).to eq({ 'kind' => 'Table', 'details' => { 'name' => 'x' } })
    end

    it 'has no error for a successful statement' do
      expect(described_class.from_response({ 'status' => 'OK', 'result' => 1 }).to_error).to be_nil
    end

    it 'wraps non-hash data as an OK result' do
      qr = described_class.from_response([1, 2, 3])
      expect(qr).to be_ok
      expect(qr.result).to eq([1, 2, 3])
    end

    it 'wraps a hash without status key as an OK result' do
      qr = described_class.from_response({ 'name' => 'Alice' })
      expect(qr).to be_ok
      expect(qr.result).to eq({ 'name' => 'Alice' })
    end
  end

  describe '#inspect' do
    it 'includes status and time' do
      qr = described_class.new(status: 'OK', time: '1ms')
      expect(qr.inspect).to include('OK')
      expect(qr.inspect).to include('1ms')
    end
  end
end
