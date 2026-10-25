# frozen_string_literal: true

RSpec.describe 'WebSocket sized numbers', :integration do
  let(:client) { new_test_client(SurrealHelper::SURREAL_WS_URL) }

  it_behaves_like 'sized numbers'
end
