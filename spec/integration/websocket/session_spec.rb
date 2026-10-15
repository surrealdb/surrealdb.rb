# frozen_string_literal: true

RSpec.describe 'WebSocket sessions', :integration do
  let(:client) { new_test_client(SurrealHelper::SURREAL_WS_URL) }

  it_behaves_like 'sessions'

  it 'lists attached sessions' do
    session = client.new_session
    expect(client.sessions).to include(session.id)
    session.close
    expect(client.sessions).not_to include(session.id)
  end
end
