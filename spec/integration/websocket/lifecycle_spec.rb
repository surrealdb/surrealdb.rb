# frozen_string_literal: true

RSpec.describe 'WebSocket session lifecycle', :integration do
  let(:client) { new_test_client(SurrealHelper::SURREAL_WS_URL) }

  it_behaves_like 'session lifecycle'
end
