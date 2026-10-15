# frozen_string_literal: true

RSpec.describe 'WebSocket token refresh', :integration do
  let(:url) { SurrealHelper::SURREAL_WS_URL }

  it_behaves_like 'token refresh'
end
