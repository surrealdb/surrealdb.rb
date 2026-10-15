# frozen_string_literal: true

RSpec.describe 'WebSocket call timeouts', :integration do
  let(:url) { SurrealHelper::SURREAL_WS_URL }
  let(:client) { new_test_client(url) }

  it_behaves_like 'call timeouts'
end
