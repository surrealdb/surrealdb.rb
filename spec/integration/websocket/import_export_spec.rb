# frozen_string_literal: true

RSpec.describe 'WebSocket import and export', :integration do
  let(:client) { new_test_client(SurrealHelper::SURREAL_WS_URL) }

  it_behaves_like 'import and export'
end
