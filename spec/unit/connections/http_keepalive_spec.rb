# frozen_string_literal: true

require 'socket'
require 'timeout'

RSpec.describe SurrealDB::Connections::HTTP do
  def http_to(server)
    described_class.new("http://127.0.0.1:#{server.port}", timeout: 2).tap(&:connect)
  end

  it 'retries once on a fresh socket when the kept-alive one turns out to be dead' do
    server = ScriptedHTTPServer.new(%i[ok drop ok])
    http = http_to(server)
    Timeout.timeout(5) do
      expect(http.send_request('ping')).to eq('pong')
      expect(http.send_request('query', ['CREATE person'])).to eq('pong')
    end
    expect(server.requests).to eq(3)
    expect(server.sockets).to eq(2)
  ensure
    http&.close
    server&.close
  end

  it 'does not retry when a fresh socket fails, and stays usable afterwards' do
    server = ScriptedHTTPServer.new(%i[drop ok])
    http = http_to(server)
    Timeout.timeout(5) do
      expect { http.send_request('query', ['CREATE person']) }.to raise_error(SurrealDB::ConnectionError)
      expect(server.requests).to eq(1)
      expect(http).to be_connected
      expect(http.send_request('ping')).to eq('pong')
    end
  ensure
    http&.close
    server&.close
  end
end

RSpec.describe SurrealDB::Connections::HTTPEndpoint, '.raise_for' do
  it 'reports a 401 as NotAllowedError with the server message, not a connection error' do
    response = Net::HTTPUnauthorized.new('1.1', '401', 'Unauthorized')
    response.instance_variable_set(:@body, 'There was a problem with authentication')
    response.instance_variable_set(:@read, true)
    expect { described_class.raise_for(response, 'request') }
      .to raise_error(SurrealDB::NotAllowedError, /problem with authentication/)
  end
end
