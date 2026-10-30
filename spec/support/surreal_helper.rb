# frozen_string_literal: true

require 'securerandom'

module SurrealHelper
  SURREAL_WS_URL = ENV.fetch('SURREALDB_WS_URL', 'ws://localhost:8000')
  SURREAL_HTTP_URL = ENV.fetch('SURREALDB_HTTP_URL', 'http://localhost:8000')
  SURREAL_USER    = ENV.fetch('SURREALDB_USER', 'root')
  SURREAL_PASS    = ENV.fetch('SURREALDB_PASS', 'root')
  SURREAL_NS      = ENV.fetch('SURREALDB_NS', 'test')
  SURREAL_DB      = ENV.fetch('SURREALDB_DB', 'test')

  # Creates a connected, authenticated client for integration tests.
  # @param url [String]
  # @return [SurrealDB::Client]
  def new_test_client(url)
    client = SurrealDB::Client.new(url)
    client.connect
    client.signin({ 'user' => SURREAL_USER, 'pass' => SURREAL_PASS })
    client.use(SURREAL_NS, SURREAL_DB)
    client
  end

  # Names of the tables in the current database.
  # @param client [SurrealDB::Client]
  # @return [Array<String>]
  def db_tables(client)
    client.query_raw('INFO FOR DB')[0].result.fetch('tables', {}).keys
  end

  # Generates a unique table name to avoid test collisions.
  # @param prefix [String]
  # @return [String]
  def unique_table(prefix = 'test')
    "#{prefix}_#{SecureRandom.hex(4)}"
  end
end

RSpec.configure do |config|
  config.include SurrealHelper, :integration
end
