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

  it 'keeps what the SDK types in a variable hold as it was set' do
    id = ['a', { 'k' => +'v' }]
    record = SurrealDB::RecordID.new('t', id)
    range = SurrealDB::Range.new(SurrealDB::BoundIncluded.new(['x']), SurrealDB::BoundExcluded.new(['y']))
    state = described_class.new
    state.track('set', ['v', [record, range]], nil)
    id << 'b'
    id[1]['k'] << 'w'
    range.begin_bound.value << 'z'
    expect(state.variables['v']).to eq([SurrealDB::RecordID.new('t', ['a', { 'k' => 'v' }]),
                                        SurrealDB::Range.new(SurrealDB::BoundIncluded.new(['x']),
                                                             SurrealDB::BoundExcluded.new(['y']))])
    expect(state.copy.variables['v'][0].id).to eq(['a', { 'k' => 'v' }])
  end

  it 'keeps the tokens and the namespace and database as they were, not the caller strings' do
    token = +'token'
    namespace = +'app'
    state = described_class.new
    state.track('authenticate', [token], nil)
    state.track('use', [namespace, SurrealDB::NONE], nil)
    pair = { 'access' => +'a1', 'refresh' => +'r1' }
    other = described_class.new
    other.track('signup', [{}], pair)
    [token, namespace, pair['access'], pair['refresh']].each { |s| s << '-changed' }
    expect([state.access_token, state.namespace]).to eq(%w[token app])
    expect([other.access_token, other.refresh_token]).to eq(%w[a1 r1])
  end
end
