# frozen_string_literal: true

require_relative 'surrealdb/version'
require_relative 'surrealdb/errors'
require_relative 'surrealdb/configuration'
require_relative 'surrealdb/server_version'
require_relative 'surrealdb/models/none'
require_relative 'surrealdb/models/table'
require_relative 'surrealdb/models/uuid'
require_relative 'surrealdb/models/record_id'
require_relative 'surrealdb/models/file_ref'
require_relative 'surrealdb/models/duration'
require_relative 'surrealdb/models/range'
require_relative 'surrealdb/models/geometry'
require_relative 'surrealdb/cbor/tags'
require_relative 'surrealdb/cbor/encoder'
require_relative 'surrealdb/cbor/decoder'
require_relative 'surrealdb/protocol/methods'
require_relative 'surrealdb/protocol/response'
require_relative 'surrealdb/protocol/rpc'
require_relative 'surrealdb/query_result'
require_relative 'surrealdb/connections/session_state'
require_relative 'surrealdb/connections/http_endpoint'
require_relative 'surrealdb/connections/base'
require_relative 'surrealdb/connections/websocket'
require_relative 'surrealdb/connections/http'
require_relative 'surrealdb/connections/reliable_restore'
require_relative 'surrealdb/connections/reliable_websocket'
require_relative 'surrealdb/query_methods'
require_relative 'surrealdb/request_methods'
require_relative 'surrealdb/transaction'
require_relative 'surrealdb/session'
require_relative 'surrealdb/client'

module SurrealDB
  class << self
    # @return [Configuration]
    def configuration
      @configuration ||= Configuration.new
    end

    # @yield [Configuration]
    def configure
      yield configuration
    end

    # Opens a connection to a SurrealDB instance.
    #
    # When called with a block, the connection is automatically closed
    # after the block returns. Without a block, the caller is responsible
    # for calling {Client#close}.
    #
    # @param url [String] connection URL (ws://, wss://, http://, https://)
    # @param options [Hash] connection options
    # @return [Client]
    def connect(url, **)
      client = Client.new(url, **)
      client.connect
      if block_given?
        begin
          yield client
        ensure
          client.close
        end
      else
        client
      end
    end
  end
end
