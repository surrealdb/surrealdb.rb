# frozen_string_literal: true

RSpec.describe 'WebSocket Live Queries', :integration do
  let(:client) { new_test_client(SurrealHelper::SURREAL_WS_URL) }
  let(:table) { unique_table('live') }

  after { client.close }

  it 'receives create notifications' do
    client.query("DEFINE TABLE #{table} SCHEMALESS")

    live_id = client.live(table)
    expect(live_id).to be_a(SurrealDB::Uuid)

    notifications = Queue.new
    client.subscribe(live_id.to_s) { |n| notifications.push(n) }

    sleep 0.1
    client.create(table, { 'name' => 'Alice' })

    notification = nil
    10.times do
      notification = notifications.pop(true)
      break
    rescue ThreadError
      sleep 0.3
    end

    expect(notification).to include('id' => live_id)
    expect(notification['action'].to_s.downcase).to eq('create')
    expect(notification['result']).to include('name' => 'Alice')
    expect(notification['result']['id'].table).to eq(table)

    client.kill(live_id.to_s)
  end
end
