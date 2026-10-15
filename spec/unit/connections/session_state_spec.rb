# frozen_string_literal: true

RSpec.describe SurrealDB::Connections::SessionState do
  it 'keeps the value a variable was set to, not the caller object that may change later' do
    value = { 'tags' => ['a'], 'name' => +'x' }
    state = described_class.new
    state.track('let', ['v', value], nil)
    value['tags'] << 'b'
    value['name'] << 'y'
    value['extra'] = true
    expect(state.variables['v']).to eq({ 'tags' => ['a'], 'name' => 'x' })
    expect(state.copy.variables['v']).to eq({ 'tags' => ['a'], 'name' => 'x' })
  end
end
