# frozen_string_literal: true

RSpec.describe SurrealDB::Connections::HTTPEndpoint do
  def base_of(url)
    described_class.new(url, timeout: 1).base.to_s
  end

  it 'maps WebSocket URLs to the matching HTTP base' do
    expect(base_of('ws://localhost:8000')).to eq('http://localhost:8000')
    expect(base_of('wss://db.example.com/rpc')).to eq('https://db.example.com')
    expect(base_of('ws://host:8000/prefix/rpc')).to eq('http://host:8000/prefix')
    expect(base_of('https://host/rpc/')).to eq('https://host')
  end

  describe '.raise_for' do
    def response(code, body)
      klass = Net::HTTPResponse::CODE_TO_OBJ.fetch(code.to_s)
      res = klass.new('1.1', code.to_s, 'msg')
      res.instance_variable_set(:@body, body)
      res.instance_variable_set(:@read, true)
      res
    end

    it 'maps auth failures to NotAllowedError with the server message' do
      body = '{"code":401,"details":"Authentication failed","information":"There was a problem with authentication"}'
      expect { described_class.raise_for(response(401, body), 'import') }
        .to raise_error(SurrealDB::NotAllowedError, /import failed \(HTTP 401\): There was a problem/)
    end

    it 'keeps a non-JSON body as the message' do
      expect { described_class.raise_for(response(500, 'boom'), 'export') }
        .to raise_error(SurrealDB::ServerError, /HTTP 500\): boom/)
    end
  end
end
