#!/usr/bin/env ruby
# frozen_string_literal: true

require 'surrealdb'

SurrealDB.connect('ws://localhost:8000') do |db|
  db.signin('user' => 'root', 'pass' => 'root')
  db.use('test', 'test')

  # Create records
  alice = db.create('person', { 'name' => 'Alice', 'age' => 30 })
  puts "Created: #{alice}"

  # Record ids are typed values; a plain string is always a table name
  bob = SurrealDB::RecordID.new('person', 'bob')
  db.create(bob, { 'name' => 'Bob', 'age' => 25 })

  # Select all
  people = db.select('person')
  puts "All people: #{people}"

  # Update
  db.update(bob, { 'name' => 'Bob', 'age' => 26 })

  # Merge
  db.merge(bob, { 'email' => 'bob@example.com' })

  # Query
  results = db.query('SELECT * FROM person WHERE age >= $min', { 'min' => 26 })
  puts "Query results: #{results}"

  # Delete
  db.delete(bob)
  puts "Remaining: #{db.select('person')}"

  # Cleanup
  db.delete('person')
end
