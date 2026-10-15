# frozen_string_literal: true

RSpec.describe 'HTTP token refresh', :integration do
  let(:url) { SurrealHelper::SURREAL_HTTP_URL }

  it_behaves_like 'token refresh'
end
