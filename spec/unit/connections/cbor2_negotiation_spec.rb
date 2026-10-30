# frozen_string_literal: true

require 'base64'
require 'digest/sha1'
require 'socket'

RSpec.describe 'cbor.2 negotiation' do # rubocop:disable RSpec/DescribeClass
  # Reads one HTTP request: its header lines (lower-cased names) and body.
  def read_request(socket)
    headers = {}
    while (line = socket.gets) && line != "\r\n"
      name, value = line.split(':', 2)
      headers[name.downcase] = value&.strip if value
    end
    return unless line

    [headers, socket.read(headers['content-length'].to_i)]
  end

  describe SurrealDB::Connections::WebSocket do
    # Accepts one upgrade and answers it with `chosen` as the subprotocol.
    def serve_upgrade(server, chosen, offered)
      Thread.new do
        socket = server.accept
        headers, = read_request(socket)
        offered << headers['sec-websocket-protocol']
        accept = Base64.strict_encode64(Digest::SHA1.digest("#{headers['sec-websocket-key']}" \
                                                            '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'))
        socket.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
                     "Sec-WebSocket-Accept: #{accept}\r\n" \
                     "#{"Sec-WebSocket-Protocol: #{chosen}\r\n" if chosen}\r\n")
        sleep 0.5
        socket.close
      rescue IOError, SystemCallError
        nil
      end
    end

    {
      'cbor.2' => :cbor2, # SurrealDB 4.0
      'cbor' => :cbor, # an older server, which does not know cbor.2
      nil => :cbor # a server that names no subprotocol
    }.each do |chosen, format|
      it "speaks #{format} when the server picks #{chosen.inspect}" do
        server = TCPServer.new('127.0.0.1', 0)
        offered = Queue.new
        thread = serve_upgrade(server, chosen, offered)
        connection = described_class.new("ws://127.0.0.1:#{server.addr[1]}", connect_timeout: 2)
        connection.connect

        expect(offered.pop).to eq('cbor.2, cbor')
        expect(connection.cbor_format).to eq(format)
      ensure
        connection&.close
        thread&.kill
        server&.close
      end
    end
  end

  describe SurrealDB::Connections::HTTP do
    # Answers each request with the next Content-Type in `types`, and keeps
    # each request's headers and body.
    def serve(server, types, seen)
      Thread.new do
        socket = server.accept
        types.each do |type|
          headers, body = read_request(socket)
          seen << [headers, body]
          answer = CBOR.encode({ 'id' => 1, 'result' => CBOR::Tagged.new(181, 7) }) if type.include?('v=2')
          answer ||= CBOR.encode({ 'id' => 1, 'result' => 7 })
          socket.write("HTTP/1.1 200 OK\r\nContent-Type: #{type}\r\n" \
                       "Content-Length: #{answer.bytesize}\r\n\r\n#{answer}")
        end
        sleep 0.5
      rescue IOError, SystemCallError
        nil
      end
    end

    def request(connection)
      connection.send_request('query', ['RETURN $n', { 'n' => SurrealDB::SizedNumber.u8(5) }])
    end

    it 'asks for cbor.2, and sends it once the server answers in it' do
      server = TCPServer.new('127.0.0.1', 0)
      seen = Queue.new
      thread = serve(server, ['application/cbor; v=2', 'application/cbor; v=2'], seen)
      connection = described_class.new("http://127.0.0.1:#{server.addr[1]}", timeout: 2)
      connection.connect

      expect(request(connection)).to eq(SurrealDB::SizedNumber.u8(7))
      first_headers, first_body = seen.pop
      expect(first_headers).to include('accept' => 'application/cbor; v=2', 'content-type' => 'application/cbor')
      expect(CBOR.decode(first_body)['params'][1]['n']).to eq(5) # widened before cbor.2 is known
      expect(connection.cbor_format).to eq(:cbor2)

      request(connection)
      second_headers, second_body = seen.pop
      expect(second_headers['content-type']).to eq('application/cbor; v=2')
      expect(CBOR.decode(second_body)['params'][1]['n']).to eq(CBOR::Tagged.new(181, 5))
    ensure
      connection&.close
      thread&.kill
      server&.close
    end

    it 'stays on plain cbor with a server that answers in it' do
      server = TCPServer.new('127.0.0.1', 0)
      seen = Queue.new
      thread = serve(server, ['application/cbor', 'application/cbor'], seen)
      connection = described_class.new("http://127.0.0.1:#{server.addr[1]}", timeout: 2)
      connection.connect

      2.times { expect(request(connection)).to eq(7) }
      2.times do
        headers, body = seen.pop
        expect(headers['content-type']).to eq('application/cbor')
        expect(CBOR.decode(body)['params'][1]['n']).to eq(5)
      end
      expect(connection.cbor_format).to eq(:cbor)
    ensure
      connection&.close
      thread&.kill
      server&.close
    end
  end
end
