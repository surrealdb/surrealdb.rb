# frozen_string_literal: true

require 'socket'
require 'timeout'

RSpec.describe SurrealDB::Connections::HTTP do
  def http_to(server)
    described_class.new("http://127.0.0.1:#{server.port}", timeout: 2).tap(&:connect)
  end

  it 'retries a repeatable request once on a fresh socket when the kept-alive one is dead' do
    server = ScriptedHTTPServer.new(%i[ok drop ok])
    http = http_to(server)
    Timeout.timeout(5) do
      expect(http.send_request('ping')).to eq('pong')
      expect(http.send_request('select', [SurrealDB::Table.new('person')])).to eq('pong')
    end
    expect(server.requests).to eq(3)
    expect(server.sockets).to eq(2)
  ensure
    http&.close
    server&.close
  end

  it 'leaves reconnecting to the next request, so a failed one does not also wait for a new socket' do
    server = ScriptedHTTPServer.new(%i[drop ok])
    http = http_to(server)
    Timeout.timeout(5) do
      expect { http.send_request('query', ['RETURN 1']) }.to raise_error(SurrealDB::ConnectionError)
      expect(http.instance_variable_get(:@http)).not_to be_started
      expect(server.sockets).to eq(1)
      expect(http.send_request('ping')).to eq('pong')
      expect(server.sockets).to eq(2)
    end
  ensure
    http&.close
    server&.close
  end

  it 'does not resend a write, which the server may already have run' do
    server = ScriptedHTTPServer.new(%i[ok drop ok])
    http = http_to(server)
    Timeout.timeout(5) do
      expect(http.send_request('ping')).to eq('pong')
      expect { http.send_request('query', ['CREATE person']) }.to raise_error(SurrealDB::RequestInterruptedError)
      expect(server.requests).to eq(2)
      expect(http.send_request('ping')).to eq('pong')
    end
  ensure
    http&.close
    server&.close
  end

  it 'does not retry when a fresh socket fails, and stays usable afterwards' do
    server = ScriptedHTTPServer.new(%i[drop ok])
    http = http_to(server)
    Timeout.timeout(5) do
      # The server read the whole request before dropping it: it may have run.
      expect { http.send_request('query', ['CREATE person']) }.to raise_error(SurrealDB::RequestInterruptedError)
      expect(server.requests).to eq(1)
      expect(http).to be_connected
      expect(http.send_request('ping')).to eq('pong')
    end
  ensure
    http&.close
    server&.close
  end
end

RSpec.describe SurrealDB::Protocol::Methods do
  it 'does not count detach as safe to repeat, as a second one finds no session' do
    expect(described_class::SAFE_TO_REPEAT).not_to include('detach')
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
