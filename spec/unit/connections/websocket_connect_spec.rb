# frozen_string_literal: true

require 'socket'
require 'timeout'

RSpec.describe SurrealDB::Connections::WebSocket do
  # Fails the example instead of hanging the suite when connect blocks.
  def connect_within(seconds, connection)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = nil
    Timeout.timeout(seconds) do
      connection.connect
    rescue SurrealDB::Error => e
      error = e
    end
    [error, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started]
  end

  context 'when the server accepts TCP but never answers the upgrade' do
    let(:server) { TCPServer.new('127.0.0.1', 0) }
    let(:held) { Queue.new }

    before do
      Thread.new do
        held << server.accept # hold the socket open, never reply
      rescue IOError
        nil
      end
    end

    after do
      held.pop(true).close until held.empty?
      server.close
    end

    it 'gives up after connect_timeout' do
      connection = described_class.new("ws://127.0.0.1:#{server.addr[1]}", timeout: 30, connect_timeout: 0.3)
      error, elapsed = connect_within(5, connection)
      expect(error).to be_a(SurrealDB::ConnectionError)
      expect(error.message).to match(/handshake timed out/)
      expect(elapsed).to be < 2
      expect(connection).not_to be_connected
    end
  end

  context 'when nothing listens on the port' do
    it 'raises ConnectionError instead of a raw Errno' do
      port = TCPServer.open('127.0.0.1', 0) { |s| s.addr[1] }
      connection = described_class.new("ws://127.0.0.1:#{port}", connect_timeout: 1)
      error, = connect_within(5, connection)
      expect(error).to be_a(SurrealDB::ConnectionError)
      expect(error.message).to match(/cannot connect/)
    end
  end

  context 'when the DNS lookup stalls' do
    it 'gives up after connect_timeout' do
      allow(Addrinfo).to receive(:getaddrinfo) { sleep 3 }
      connection = described_class.new('ws://db.example.com:8000', connect_timeout: 0.3)
      error, elapsed = connect_within(5, connection)
      expect(error).to be_a(SurrealDB::ConnectionError)
      expect(error.message).to match(/DNS lookup .* timed out/)
      expect(elapsed).to be < 1
    end
  end

  context 'when the host resolves to several unreachable addresses' do
    it 'spends one connect_timeout across all of them, not one each' do
      black_hole = Array.new(3) do
        addr = instance_double(Addrinfo)
        allow(addr).to receive(:connect) do |timeout:|
          sleep timeout
          raise Errno::ETIMEDOUT
        end
        addr
      end
      allow(Addrinfo).to receive(:getaddrinfo).and_return(black_hole)
      connection = described_class.new('ws://db.example.com:8000', connect_timeout: 0.3)
      error, elapsed = connect_within(5, connection)
      expect(error.message).to match(/TCP connect .* timed out/)
      expect(elapsed).to be < 0.6
    end

    it 'moves on to the next address when one times out early, while time is left' do
      timed_out = instance_double(Addrinfo)
      allow(timed_out).to receive(:connect).and_raise(Errno::ETIMEDOUT)
      second = instance_double(Addrinfo)
      allow(second).to receive(:connect).and_raise(Errno::ECONNREFUSED)
      allow(Addrinfo).to receive(:getaddrinfo).and_return([timed_out, second])
      error, = connect_within(5, described_class.new('ws://db.example.com:8000', connect_timeout: 1))
      expect(error.message).to start_with('cannot connect to db.example.com:8000')
      expect(second).to have_received(:connect)
    end

    it 'moves on to the next address when one refuses' do
      refused = instance_double(Addrinfo)
      allow(refused).to receive(:connect).and_raise(Errno::ECONNREFUSED)
      second = instance_double(Addrinfo)
      allow(second).to receive(:connect).and_raise(Errno::EHOSTUNREACH)
      allow(Addrinfo).to receive(:getaddrinfo).and_return([refused, second])
      error, = connect_within(5, described_class.new('ws://db.example.com:8000', connect_timeout: 1))
      expect(error.message).to start_with('cannot connect to db.example.com:8000')
      expect(second).to have_received(:connect)
    end
  end

  context 'when a TLS server stalls partway through a record' do
    it 'still gives up at the deadline instead of blocking in a read' do
      connection = described_class.new('wss://db.example.com', connect_timeout: 0.3)
      tcp = instance_double(IO, wait_readable: true) # bytes arrived, but not a whole TLS record
      ssl = instance_double(OpenSSL::SSL::SSLSocket, to_io: tcp)
      allow(ssl).to receive(:read_nonblock).and_raise(OpenSSL::SSL::SSLErrorWaitReadable)
      allow(ssl).to receive(:readpartial) { sleep 5 }
      connection.instance_variable_set(:@socket, ssl)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.3
      expect { Timeout.timeout(2) { connection.send(:wait_for_open, deadline) } }
        .to raise_error(SurrealDB::ConnectionError, /handshake timed out/)
    end
  end

  it 'defaults connect_timeout to the request timeout' do
    expect(described_class.new('ws://localhost:1', timeout: 7).connect_timeout).to eq(7)
  end
end
