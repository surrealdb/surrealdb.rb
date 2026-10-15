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

    it 'drops the previous identity when a different token is presented' do
      state.track('signin', [{ 'user' => 'u' }], pair)
      state.track('authenticate', ['someone-else'], nil)
      expect(state.access_token).to eq('someone-else')
      expect(state.refresh_token).to be_nil
      expect(state.signin).to be_nil
      expect(state).not_to be_renewable
    end
  end
end
