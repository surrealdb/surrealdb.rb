# frozen_string_literal: true

RSpec.describe SurrealDB::Api do
  let(:target) { instance_double(SurrealDB::Client) }
  let(:api) { described_class.new(target, '/v1') }
  let(:answer) { { 'status' => 200, 'headers' => { 'x' => 'y' }, 'body' => { 'ok' => true } } }

  before { allow(target).to receive(:query).and_return([answer]) }

  def sent_request
    vars = nil
    expect(target).to have_received(:query).with('RETURN api::invoke($api_path, $api_request)', anything) do |_, v|
      vars = v
    end
    vars
  end

  it 'invokes api::invoke with the prefixed path and the request' do
    api.header('x-tenant', 'acme')
    response = api.post('/users', { 'name' => 'Ann' }, query: { page: 2 }, headers: { 'x-trace' => '1' })

    expect(sent_request).to eq(
      'api_path' => '/v1/users',
      'api_request' => { 'method' => 'post', 'body' => { 'name' => 'Ann' }, 'query' => { 'page' => 2 },
                         'headers' => { 'x-tenant' => 'acme', 'x-trace' => '1' } }
    )
    expect([response.status, response.headers, response.value]).to eq([200, { 'x' => 'y' }, { 'ok' => true }])
  end

  it 'leaves the body out when there is none, and removes a header set to nil' do
    api.header('x-tenant', 'acme').header('x-tenant', nil)
    api.get('/users')
    expect(sent_request['api_request']).to eq('method' => 'get', 'headers' => {}, 'query' => {})
  end

  it 'sends an explicit nil body as NULL' do
    api.post('/events', nil)
    expect(sent_request['api_request']).to include('body' => nil)
  end

  it 'joins the prefix and the path with exactly one slash' do
    paths = []
    allow(target).to receive(:query) do |_, vars|
      paths << vars['api_path']
      [answer]
    end
    described_class.new(target, '/v1/').get('/users')
    described_class.new(target, '/v1').get('users')
    described_class.new(target, '/v1').get
    described_class.new(target).get('users')
    described_class.new(target).get
    expect(paths).to eq(['/v1/users', '/v1/users', '/v1', '/users', '/'])
  end

  it 'raises ApiError for the value of an unsuccessful response' do
    allow(target).to receive(:query).and_return([{ 'status' => 403, 'body' => 'nope' }])
    response = api.delete('/users/1')
    expect(response).not_to be_success
    expect { response.value }.to raise_error(SurrealDB::ApiError, %r{DELETE /v1/users/1 answered 403}) { |e|
      expect(e.response).to be(response)
    }
  end
end
