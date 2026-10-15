# frozen_string_literal: true

require 'base64'
require 'json'

RSpec.describe SurrealDB::Connections::Base, '#send_request token renewal' do
  # Records requests and answers signin/signup/refresh with tokens that
  # expire when the test chooses.
  let(:fake_class) do
    Class.new(described_class) do
      attr_reader :calls
      attr_accessor :next_expiry, :fail_on

      def initialize(url, **options)
        super
        @calls = []
        @connected = true
      end

      protected

      def execute(method, *, **)
        @calls << method
        raise SurrealDB::ConnectionError, 'connection closed' if method == fail_on

        case method
        when 'signin' then token
        when 'refresh' then { 'access' => token, 'refresh' => "r#{@calls.size}" }
        when 'signup' then { 'access' => token, 'refresh' => 'r0' }
        else 'ok'
        end
      end

      private

      def token
        # issued an hour ago, so the margin is not capped by a short lifetime
        claims = { 'iat' => Time.now.to_i - 3600, 'exp' => next_expiry.to_i }
        "h.#{Base64.urlsafe_encode64(JSON.generate(claims), padding: false)}.s"
      end
    end
  end

  let(:options) { {} }
  let(:connection) { fake_class.new('ws://localhost:8000', **options) }

  it 'refreshes a token about to expire before the next request' do
    connection.next_expiry = Time.now + 30 # inside the default 60s margin
    connection.send_request('signup', [{}])
    connection.next_expiry = Time.now + 3600
    connection.send_request('select', ['person'])
    expect(connection.calls).to eq(%w[signup refresh select])
    connection.send_request('select', ['person'])
    expect(connection.calls.count('refresh')).to eq(1)
  end

  it 'signs in again when there is no refresh token' do
    connection.next_expiry = Time.now + 30
    connection.send_request('signin', [{ 'user' => 'root', 'pass' => 'root' }])
    connection.next_expiry = Time.now + 3600
    connection.send_request('query', ['RETURN 1'])
    expect(connection.calls).to eq(%w[signin signin query])
  end

  it 'leaves a token that is not expiring alone' do
    connection.next_expiry = Time.now + 3600
    connection.send_request('signup', [{}])
    connection.send_request('select', ['person'])
    expect(connection.calls).to eq(%w[signup select])
  end

  it 'does not renew around authentication requests' do
    connection.next_expiry = Time.now - 1
    connection.send_request('signup', [{}])
    connection.send_request('authenticate', ['other'])
    connection.send_request('invalidate')
    expect(connection.calls).to eq(%w[signup authenticate invalidate])
  end

  it 'renews before an import or export, which go over HTTP rather than RPC' do
    endpoint = instance_double(SurrealDB::Connections::HTTPEndpoint)
    allow(endpoint).to receive(:request) { connection.calls << 'POST /import' }
    allow(connection).to receive(:http_endpoint).and_return(endpoint)
    connection.next_expiry = Time.now + 30
    connection.send_request('signup', [{}])
    connection.next_expiry = Time.now + 3600
    connection.http_request(:post, '/import', body: 'OPTION IMPORT;')
    expect(connection.calls).to eq(['signup', 'refresh', 'POST /import'])
    expect(endpoint).to have_received(:request)
      .with(:post, '/import', state: connection.session_state, body: 'OPTION IMPORT;')
  end

  it 'reports a connection lost while renewing as the request never having been sent' do
    connection.next_expiry = Time.now + 30
    connection.send_request('signup', [{}])
    connection.fail_on = 'refresh'
    expect { connection.send_request('create', ['person']) }
      .to raise_error(SurrealDB::NotConnectedError, /renewing the access token.*'create' was not sent/)
    expect(connection.calls).not_to include('create')
  end

  context 'with renew_tokens: false' do
    let(:options) { { renew_tokens: false } }

    it 'never renews' do
      connection.next_expiry = Time.now - 1
      connection.send_request('signup', [{}])
      connection.send_request('select', ['person'])
      expect(connection.calls).to eq(%w[signup select])
    end
  end
end
