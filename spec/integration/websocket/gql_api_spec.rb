# frozen_string_literal: true

RSpec.describe 'WebSocket GQL and user-defined APIs', :integration do
  let(:client) { new_test_client(SurrealHelper::SURREAL_WS_URL) }

  it_behaves_like 'gql and user-defined APIs'
end
