# frozen_string_literal: true

RSpec.describe 'HTTP call timeouts', :integration do
  let(:url) { SurrealHelper::SURREAL_HTTP_URL }
  let(:client) { new_test_client(url) }

  it_behaves_like 'call timeouts'
end
