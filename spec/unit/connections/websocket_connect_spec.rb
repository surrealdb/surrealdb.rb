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

  it 'defaults connect_timeout to the request timeout' do
    expect(described_class.new('ws://localhost:1', timeout: 7).connect_timeout).to eq(7)
  end
end
