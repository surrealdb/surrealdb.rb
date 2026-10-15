# frozen_string_literal: true

require 'socket'
require 'uri'

# A TCP proxy in front of the test server that can cut every open
# connection, to test what clients do when the network drops.
class TCPProxy
  attr_reader :port

  # @param upstream [String] URL of the real server, e.g. ws://localhost:8000
  def initialize(upstream)
    uri = URI.parse(upstream)
    @upstream_host = uri.host
    @upstream_port = uri.port
    @server = TCPServer.new('127.0.0.1', 0)
    @port = @server.addr[1]
    @mutex = Mutex.new
    @sockets = []
    @accepted = 0
    @thread = Thread.new { accept_loop }
  end

  # @param scheme [String]
  # @return [String] URL that reaches the upstream through this proxy
  def url(scheme = 'ws')
    "#{scheme}://127.0.0.1:#{@port}"
  end

  # How many client connections the proxy has accepted so far.
  def connections
    @mutex.synchronize { @accepted }
  end

  # Cuts every open connection, as a network failure would.
  def drop_all
    sockets = @mutex.synchronize { @sockets.dup.tap { @sockets.clear } }
    sockets.each do |s|
      s.close
    rescue IOError
      nil
    end
  end

  def close
    drop_all
    @thread.kill
    @server.close
  end

  private

  def accept_loop
    loop do
      client = @server.accept
      upstream = TCPSocket.new(@upstream_host, @upstream_port)
      @mutex.synchronize do
        @accepted += 1
        @sockets.push(client, upstream)
      end
      pipe(client, upstream)
      pipe(upstream, client)
    end
  rescue IOError, SystemCallError
    nil
  end

  def pipe(from, to)
    Thread.new do
      loop { to.write(from.readpartial(16_384)) }
    rescue IOError, SystemCallError
      [from, to].each do |s|
        s.close
      rescue IOError
        nil
      end
    end
  end
end
