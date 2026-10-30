# frozen_string_literal: true

RSpec.describe 'HTTP transactions', :integration do
  let(:client) { new_test_client(SurrealHelper::SURREAL_HTTP_URL) }

  after { client.close }

  it 'refuses interactive transactions, which the server only offers over WebSocket' do
    expect { client.begin_transaction }.to raise_error(SurrealDB::UnsupportedError, /transactions/)
  end
end
