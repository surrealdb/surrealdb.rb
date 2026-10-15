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

  it 'keeps the sign-in credentials as they were sent' do
    credentials = { 'user' => 'u', 'pass' => +'p' }
    state = described_class.new
    state.track('signin', [credentials], 'token')
    credentials['pass'] << 'changed'
    credentials.delete('user')
    expect(state.signin).to eq(['signin', [{ 'user' => 'u', 'pass' => 'p' }]])
  end

  it 'forgets the sign-in credentials when a signup or another token changes the identity' do
    state = described_class.new
    state.track('signin', [{ 'user' => 'u' }], 'token')
    state.track('authenticate', ['token'], nil) # the same token again: still that sign-in
    expect(state.signin).not_to be_nil
    state.track('authenticate', ['someone-else'], nil)
    expect(state.signin).to be_nil
    state.track('signin', [{ 'user' => 'u' }], 'token')
    state.track('signup', [{ 'ac' => 'user' }], 'new-token')
    expect(state.signin).to be_nil
  end

  it 'keeps a Set variable as it was set, too' do
    value = Set[['a'], ['b']]
    state = described_class.new
    state.track('set', ['v', value], nil)
    value << ['c']
    value.first << 'x'
    expect(state.variables['v'].to_a).to eq([['a'], ['b']])
  end
end
