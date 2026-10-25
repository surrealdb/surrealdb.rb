# frozen_string_literal: true

RSpec.describe 'HTTP sized numbers', :integration do
  let(:client) { new_test_client(SurrealHelper::SURREAL_HTTP_URL) }

  it_behaves_like 'sized numbers'
end
