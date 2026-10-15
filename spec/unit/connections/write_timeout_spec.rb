# frozen_string_literal: true

require 'base64'
require 'digest'
require 'socket'
require 'timeout'

# A peer that accepts connections (and, for WebSocket, the upgrade) but
# never reads what it is sent, so a large enough request blocks in the write.
class BlackHoleServer
  attr_reader :port

  def initialize(websocket: false)
    @server = TCPServer.new('127.0.0.1', 0)
    @server.setsockopt(Socket::SOL_SOCKET, Socket::SO_RCVBUF, 4096)
    @port = @server.addr[1]
    @sockets = Queue.new
    @thread = Thread.new do
      loop do
        socket = @server.accept
        upgrade(socket) if websocket
        @sockets << socket
      end
    rescue IOError, SystemCallError
      nil
    end
  end

  def close
    @thread.kill
    @sockets.pop.close until @sockets.empty?
    @server.close
  end

  private

  def upgrade(socket)
    request = +''
    request << socket.readpartial(4096) until request.include?("\r\n\r\n")
    key = request[/Sec-WebSocket-Key: (.+)\r\n/i, 1]
    accept = Base64.strict_encode64(Digest::SHA1.digest("#{key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
    socket.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
                 "Sec-WebSocket-Accept: #{accept}\r\nSec-WebSocket-Protocol: cbor\r\n\r\n")
  end
end

RSpec.describe 'Writing a request within its timeout' do # rubocop:disable RSpec/DescribeClass
  let(:server) { BlackHoleServer.new(websocket: websocket) }
  let(:websocket) { false }
  let(:payload) { 'x' * 16_000_000 } # more than the socket buffers hold

  after { server.close }

  def within_timeout
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = nil
    Timeout.timeout(10) do
      yield
    rescue SurrealDB::Error => e
      error = e
    end
    [error, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started]
  end

  it 'gives up on an HTTP route body the server does not read' do
    endpoint = SurrealDB::Connections::HTTPEndpoint.new("http://127.0.0.1:#{server.port}", timeout: 30)
    error, elapsed = within_timeout { endpoint.request(:post, '/import', body: payload, timeout: 0.3) }
    expect(error).to be_a(SurrealDB::TimeoutError)
    expect(elapsed).to be < 2
  end

  it 'gives up on an HTTP RPC request the server does not read, which it did not run' do
    http = SurrealDB::Connections::HTTP.new("http://127.0.0.1:#{server.port}", timeout: 30).tap(&:connect)
    error, elapsed = within_timeout { http.send_request('query', [payload], timeout: 0.3) }
    expect(error).to be_a(SurrealDB::TimeoutError)
    expect(error).not_to be_sent
    expect(elapsed).to be < 2
  ensure
    http&.close
  end

  context 'with a WebSocket connection' do
    let(:websocket) { true }

    it 'counts writing the frame against the timeout and drops the connection the frame broke' do
      ws = SurrealDB::Connections::WebSocket.new("ws://127.0.0.1:#{server.port}", timeout: 30)
      ws.connect
      error, elapsed = within_timeout { ws.send_request('query', [payload], timeout: 0.3) }
      expect(error).to be_a(SurrealDB::TimeoutError)
      expect(error).not_to be_sent
      expect(elapsed).to be < 2
      expect(ws).not_to be_connected
    ensure
      ws&.close
    end
  end
end
