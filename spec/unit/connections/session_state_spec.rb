# frozen_string_literal: true

require 'base64'
require 'json'

RSpec.describe SurrealDB::Connections::SessionState do
  subject(:state) { described_class.new }

  def jwt(claims)
    encode = ->(h) { Base64.urlsafe_encode64(JSON.generate(h), padding: false) }
    "#{encode.call({ 'alg' => 'HS512', 'typ' => 'JWT' })}.#{encode.call(claims)}.signature"
  end

  let(:now) { Time.at(1_000_000) }

  describe 'token expiry' do
    it 'reads exp from a JWT access token' do
      state.track('signin', [{}], jwt('iat' => now.to_i, 'exp' => now.to_i + 3600))
      expect(state.access_expires_at).to eq(now + 3600)
    end

    it 'knows nothing about a token that is not a JWT' do
      state.track('signin', [{}], 'opaque-token')
      expect(state.access_expires_at).to be_nil
      expect(state.expiring?(60, now)).to be(false)
    end

    it 'is expiring within the margin' do
      state.track('signin', [{}], jwt('iat' => now.to_i, 'exp' => now.to_i + 3600))
      expect(state.expiring?(60, now + 3500)).to be(false)
      expect(state.expiring?(60, now + 3541)).to be(true)
      expect(state.expiring?(60, now + 4000)).to be(true)
    end

    it 'caps the margin at a quarter of the token lifetime' do
      state.track('signin', [{}], jwt('iat' => now.to_i, 'exp' => now.to_i + 8))
      expect(state.expiring?(60, now + 1)).to be(false) # 7s left; margin capped at 2s
      expect(state.expiring?(60, now + 6.5)).to be(true)
    end
  end

  describe 'tokens' do
    let(:pair) { { 'access' => jwt('exp' => 1), 'refresh' => 'r1' } }

    it 'keeps the refresh token from signin, signup and refresh' do
      state.track('signup', [{}], pair)
      expect(state.tokens).to eq(pair)
      state.track('refresh', [pair], { 'access' => 'a2', 'refresh' => 'r2' })
      expect(state.tokens).to eq({ 'access' => 'a2', 'refresh' => 'r2' })
      expect(state).to be_renewable
    end

    it 'forgets a revoked refresh token' do
      state.track('signin', [{}], pair)
      state.track('revoke', [pair], nil)
      expect(state.refresh_token).to be_nil
      expect(state.access_token).to eq(pair['access'])
    end

    it 'keeps credentials when the same token is presented again' do
      state.track('signin', [{ 'user' => 'u' }], pair)
      state.track('authenticate', [pair['access']], nil)
      expect(state.refresh_token).to eq('r1')
      expect(state.signin).to eq(['signin', [{ 'user' => 'u' }]])
    end

    it 'drops the previous sign-in credentials when refreshing another token pair' do
      state.track('signin', [{ 'user' => 'u' }], pair)
      state.track('refresh', [pair], { 'access' => 'a2', 'refresh' => 'r2' })
      expect(state.signin).to eq(['signin', [{ 'user' => 'u' }]]) # its own pair
      state.track('refresh', [{ 'access' => 'bob', 'refresh' => 'rb' }], { 'access' => 'b2', 'refresh' => 'rb2' })
      expect(state.signin).to be_nil
      expect(state.tokens).to eq({ 'access' => 'b2', 'refresh' => 'rb2' })
    end

    it 'drops the previous sign-in credentials on signup' do
      state.track('signin', [{ 'user' => 'u' }], pair)
      state.track('signup', [{ 'ac' => 'user' }], 'other-token')
      expect(state.signin).to be_nil
      expect(state).not_to be_renewable
    end

    it 'drops the previous identity when a different token is presented' do
      state.track('signin', [{ 'user' => 'u' }], pair)
      state.track('authenticate', ['someone-else'], nil)
      expect(state.access_token).to eq('someone-else')
      expect(state.refresh_token).to be_nil
      expect(state.signin).to be_nil
      expect(state).not_to be_renewable
    end
  end

  it 'keeps the value a variable was set to, not the caller object that may change later' do
    value = { 'tags' => ['a'], 'name' => +'x' }
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

  it 'selects the namespace and database a scoped sign-in or sign-up selects on the server' do
    state = described_class.new
    state.track('use', %w[old olddb], nil)
    state.track('signin', [{ 'NS' => 'app', 'user' => 'u', 'pass' => 'p' }], 'token')
    expect([state.namespace, state.database]).to eq(%w[app olddb])
    state.track('signup', [{ 'ns' => 'shop', 'db' => 'prod', 'ac' => 'user' }], 'token2')
    expect([state.namespace, state.database]).to eq(%w[shop prod])
    state.track('signin', [{ 'user' => 'root', 'pass' => 'root' }], 'token3') # root: no scope
    expect([state.namespace, state.database]).to eq(%w[shop prod])
  end

  it 'selects the namespace and database named in a token it authenticates with' do
    payload = Base64.urlsafe_encode64(JSON.generate('NS' => 'app', 'DB' => 'prod'), padding: false)
    state = described_class.new
    state.track('authenticate', ["e30.#{payload}.sig"], nil)
    expect([state.namespace, state.database]).to eq(%w[app prod])
    state.track('authenticate', ['not-a-jwt'], nil)
    expect([state.namespace, state.database]).to eq(%w[app prod])
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

  it 'keeps a refresh token it is given as it was, not the caller string' do
    token = +'refresh-1'
    state = described_class.new
    state.refresh_token = token
    token << 'changed'
    expect(state.refresh_token).to eq('refresh-1')
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

  it 'selects the scope of the identity a refresh switches to' do
    claims = Base64.urlsafe_encode64(JSON.generate('NS' => 'other', 'DB' => 'tenant2'), padding: false)
    state = described_class.new
    state.track('signin', [{ 'NS' => 'app', 'DB' => 'prod', 'user' => 'u', 'pass' => 'p' }], 'token')
    state.track('refresh', [{ 'access' => 'someone-else', 'refresh' => 'r' }], { 'access' => "e30.#{claims}.s" })
    expect([state.namespace, state.database]).to eq(%w[other tenant2])
  end
end
