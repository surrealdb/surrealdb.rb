# frozen_string_literal: true

RSpec.describe SurrealDB::Configuration do
  it 'has no request timeout by default' do
    expect(described_class.new.timeout).to be_nil
  end
end
