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

  it 'connects to the default port of the scheme when the URL has none' do
    ports = %w[wss://db.example.com https://db.example.com ws://db.example.com http://db.example.com wss://h:9443]
            .map { |url| described_class.new(url, timeout: 1).base.port }
    expect(ports).to eq([443, 443, 80, 80, 9443])
  end

  it 'opens HTTPS endpoints with TLS on port 443' do
    http = instance_double(Net::HTTP, :use_ssl= => nil, :open_timeout= => nil, :write_timeout= => nil,
                                      :read_timeout= => nil)
    allow(Net::HTTP).to receive(:new).and_return(http)
    allow(http).to receive(:start).and_raise(Errno::ECONNREFUSED)
    endpoint = described_class.new('wss://db.example.com/rpc', timeout: 1)
    expect { endpoint.request(:get, '/health') }.to raise_error(SurrealDB::ConnectionError)
    expect(Net::HTTP).to have_received(:new).with('db.example.com', 443)
    expect(http).to have_received(:use_ssl=).with(true)
  end

  it 'raises an error the body IO raised as it was, not as a network failure' do
    server = TCPServer.new('127.0.0.1', 0)
    reader = Thread.new do
      socket = server.accept
      loop { socket.readpartial(4096) }
    rescue IOError, SystemCallError
      nil
    end
    body = Object.new
    def body.read(*) = raise(Errno::EIO, 'disk')
    endpoint = described_class.new("http://127.0.0.1:#{server.addr[1]}", timeout: 2)
    expect { endpoint.request(:post, '/import', body: body) }.to raise_error(Errno::EIO, /disk/)
  ensure
    server&.close
    reader&.kill
  end

  it 'times out writing a body the server does not read' do
    server = TCPServer.new('127.0.0.1', 0)
    accepted = Thread.new { server.accept }
    endpoint = described_class.new("http://127.0.0.1:#{server.addr[1]}", timeout: 0.3)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect { endpoint.request(:post, '/import', body: 'x' * 64_000_000) }
      .to raise_error(SurrealDB::TimeoutError, %r{/import timed out})
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 3
  ensure
    server&.close
    accepted&.value&.close
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
