#!/usr/bin/env ruby
# frozen_string_literal: true

require 'surrealdb'

SurrealDB.connect('ws://localhost:8000') do |db|
  db.signin('user' => 'root', 'pass' => 'root')
  db.use('test', 'test')

  # Start live query (the table must exist)
  db.query('DEFINE TABLE IF NOT EXISTS events SCHEMALESS')
  live_id = db.live('events')
  puts "Live query started: #{live_id}"

  # Subscribe to changes
  db.subscribe(live_id) do |notification|
    action = notification['action']
    result = notification['result']
    puts "[#{action}] #{result}"
  end

  # Trigger some changes
  db.create('events', { 'type' => 'login', 'user' => 'alice' })
  sleep 0.5

  db.create('events', { 'type' => 'purchase', 'user' => 'bob' })
  sleep 0.5

  # Cleanup
  db.kill(live_id)
  db.delete('events')
  puts 'Done'
end
