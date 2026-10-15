# frozen_string_literal: true

RSpec.describe 'HTTP error statuses', :integration do
  let(:client) { new_test_client(SurrealHelper::SURREAL_HTTP_URL) }

  after { client.close }

  it 'reports a rejected token as NotAllowedError and keeps the client usable' do
    good = client.connection.session_state.access_token
    client.connection.session_state.access_token = 'not-a-token'
    expect { client.query('RETURN 1') }.to raise_error(SurrealDB::NotAllowedError) { |e|
      expect(e.code).to eq(401)
    }
    client.connection.session_state.access_token = good
    expect(client.query_raw('RETURN 1')[0].result).to eq(1)
  end
end
