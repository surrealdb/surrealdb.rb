# frozen_string_literal: true

require 'socket'

# A tiny HTTP/1.1 server that follows a script, one step per request:
# :ok answers on the same kept-alive socket, :drop reads the request and
# closes the socket without answering (what a server does when it closes
# an idle keep-alive connection just as a request arrives), :refuse answers
# 401 and then closes the socket without announcing it (what the server does
# when it refuses a request before reading its body).
class ScriptedHTTPServer
  attr_reader :port, :requests, :sockets

  def initialize(script)
    @script = script.dup
    @server = TCPServer.new('127.0.0.1', 0)
    @port = @server.addr[1]
    @requests = 0
    @sockets = 0
    @thread = Thread.new { serve }
  end

  def close
    @thread.kill
    @server.close
  end

  private

  def serve
    until @script.empty?
      socket = @server.accept
      @sockets += 1
      handle(socket)
    end
  rescue IOError
    nil
  end

  def handle(socket)
    until @script.empty?
      break unless read_request(socket)

      @requests += 1
      case @script.shift
      when :ok then respond(socket)
      when :drop then break
      when :refuse
        refuse(socket)
        break
      end
    end
  ensure
    socket.close
  end

  def read_request(socket)
    length = 0
    while (line = socket.gets)
      break if line == "\r\n"

      length = line.split(':', 2)[1].to_i if line.downcase.start_with?('content-length')
    end
    line && socket.read(length)
  end

  def refuse(socket)
    body = 'InvalidToken'
    socket.write("HTTP/1.1 401 Unauthorized\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}")
  end

  def respond(socket)
    body = CBOR.encode({ 'id' => 1, 'result' => 'pong' })
    socket.write("HTTP/1.1 200 OK\r\nContent-Type: application/cbor\r\n" \
                 "Content-Length: #{body.bytesize}\r\nConnection: keep-alive\r\n\r\n#{body}")
  end
end
