# frozen_string_literal: true

RSpec.describe 'HTTP import and export', :integration do
  let(:client) { new_test_client(SurrealHelper::SURREAL_HTTP_URL) }

  it_behaves_like 'import and export'
end
