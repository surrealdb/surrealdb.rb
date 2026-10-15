# frozen_string_literal: true

require 'uri'

module SurrealDB
  # Main client for interacting with SurrealDB.
  #
  # Provides a unified API across WebSocket and HTTP transports,
  # selected automatically based on the connection URL scheme.
  #
  # @example
  #   client = SurrealDB::Client.new("ws://localhost:8000")
  #   client.connect
  #   client.use("test", "test")
  #   client.signin("user" => "root", "pass" => "root")
  #   results = client.select("users")
  #   client.close
  class Client
    # @return [Connections::Base]
    attr_reader :connection

    # @param url [String] connection URL (ws://, wss://, http://, https://)
    # @param options [Hash] connection options (:timeout, etc.)
    def initialize(url, **options)
      @url = url
      @options = options
      @connection = build_connection(url, **options)
    end

    # Opens the connection to SurrealDB.
    # @return [self]
    def connect
      @connection.connect
      self
    end

    # Closes the connection.
    # @return [void]
    def close
      @connection.close
    end

    # @return [Boolean]
    def connected?
      @connection.connected?
    end

    # --- Namespace / Database ---

    # Selects the namespace and database to use.
    # @param namespace [String]
    # @param database [String]
    # @return [void]
    def use(namespace, database)
      @connection.send_request(Protocol::Methods::USE, [namespace, database])
    end

    # --- Authentication ---

    # Signs in to SurrealDB.
    # @param credentials [Hash] authentication credentials (string keys)
    # @return [String, Hash] JWT token or tokens hash
    def signin(credentials = {})
      @connection.send_request(Protocol::Methods::SIGNIN, [credentials])
    end

    # Signs up a new user.
    # @param credentials [Hash] signup credentials (string keys)
    # @return [String, Hash] JWT token or tokens hash
    def signup(credentials = {})
      @connection.send_request(Protocol::Methods::SIGNUP, [credentials])
    end

    # Authenticates with an existing JWT token.
    # @param token [String]
    # @return [void]
    def authenticate(token)
      @connection.send_request(Protocol::Methods::AUTHENTICATE, [token])
    end

    # Invalidates the current session.
    # @return [void]
    def invalidate
      @connection.send_request(Protocol::Methods::INVALIDATE)
    end

    # --- Variables ---

    # Sets a connection-scoped variable.
    # @param key [String]
    # @param value [Object]
    # @return [void]
    def set(key, value)
      @connection.send_request(Protocol::Methods::LET, [key, value])
    end
    alias let set

    # Removes a connection-scoped variable.
    # @param key [String]
    # @return [void]
    def unset(key)
      @connection.send_request(Protocol::Methods::UNSET, [key])
    end

    # --- CRUD ---

    # Selects all records from a table, or a single record by ID.
    #
    # A String is always a table name. To target one record, pass a
    # {RecordID} (or {StringRecordID}); a String containing ":" raises
    # ArgumentError rather than being guessed at.
    #
    # @param resource [String, Table, RecordID, StringRecordID] table name or record id
    # @return [Array, Hash] records
    def select(resource)
      @connection.send_request(Protocol::Methods::SELECT, [resource_param(resource)])
    end

    # Creates a new record.
    # @param resource [String, Table, RecordID, StringRecordID] table name or record id
    # @param data [Hash, nil] record content
    # @return [Hash] created record
    def create(resource, data = nil)
      params = [resource_param(resource)]
      params << data unless data.nil?
      @connection.send_request(Protocol::Methods::CREATE, params)
    end

    # Inserts one or more records into a table.
    # @param table [String, Table] table name
    # @param data [Hash, Array<Hash>] record(s) to insert
    # @return [Array] inserted records
    def insert(table, data)
      @connection.send_request(Protocol::Methods::INSERT, [table_param(table), data])
    end

    # Inserts a relation record.
    # @param table [String, Table] relation table name
    # @param data [Hash] relation data (must include :in and :out)
    # @return [Array] inserted relation records
    def insert_relation(table, data)
      @connection.send_request(Protocol::Methods::INSERT_RELATION, [table_param(table), data])
    end

    # Replaces a record or all records in a table.
    # @param resource [String, Table, RecordID, StringRecordID] table name or record id
    # @param data [Hash] replacement content
    # @return [Object] updated record(s)
    def update(resource, data)
      @connection.send_request(Protocol::Methods::UPDATE, [resource_param(resource), data])
    end

    # Upserts a record (insert or update).
    # @param resource [String, Table, RecordID, StringRecordID] table name or record id
    # @param data [Hash] record content
    # @return [Object] upserted record(s)
    def upsert(resource, data)
      @connection.send_request(Protocol::Methods::UPSERT, [resource_param(resource), data])
    end

    # Deep-merges data into a record.
    # @param resource [String, Table, RecordID, StringRecordID] table name or record id
    # @param data [Hash] data to merge
    # @return [Object] merged record(s)
    def merge(resource, data)
      @connection.send_request(Protocol::Methods::MERGE, [resource_param(resource), data])
    end

    # Applies JSON Patch operations to a record.
    # @param resource [String, Table, RecordID, StringRecordID] table name or record id
    # @param patches [Array<Hash>] patch operations
    # @return [Object] patched record(s)
    def patch(resource, patches)
      @connection.send_request(Protocol::Methods::PATCH, [resource_param(resource), patches])
    end

    # Deletes a record or all records from a table.
    # @param resource [String, Table, RecordID, StringRecordID] table name or record id
    # @return [Object] deleted record(s)
    def delete(resource)
      @connection.send_request(Protocol::Methods::DELETE, [resource_param(resource)])
    end

    # Creates a graph relation between two records.
    # @param from [RecordID, StringRecordID, Array<RecordID>] source record(s)
    # @param relation [String, Table] relation table
    # @param to [RecordID, StringRecordID, Array<RecordID>] target record(s)
    # @param data [Hash, nil] relation content
    # @return [Object] created relation
    def relate(from, relation, to, data = nil)
      params = [record_param(from), table_param(relation), record_param(to)]
      params << data unless data.nil?
      @connection.send_request(Protocol::Methods::RELATE, params)
    end

    # --- Query ---

    # Executes a SurrealQL query.
    # @param sql [String] SurrealQL statement(s)
    # @param vars [Hash] query variables
    # @return [Array] array of result sets (one per statement)
    def query(sql, vars = {})
      params = [sql]
      params << vars unless vars.empty?
      @connection.send_request(Protocol::Methods::QUERY, params)
    end

    # Executes a SurrealQL query and returns structured per-statement results.
    # Unlike {#query}, this returns {QueryResult} objects with status, timing,
    # and per-statement error information.
    # @param sql [String] SurrealQL statement(s)
    # @param vars [Hash] query variables
    # @return [Array<QueryResult>]
    def query_raw(sql, vars = {})
      params = [sql]
      params << vars unless vars.empty?
      raw = @connection.send_request(Protocol::Methods::QUERY, params)
      Array(raw).map { |stmt| QueryResult.from_response(stmt) }
    end

    # Runs a SurrealDB function.
    # @param function_name [String]
    # @param args [Array] function arguments
    # @param version [String, nil] optional function version
    # @return [Object]
    def run(function_name, *args, version: nil)
      @connection.send_request(Protocol::Methods::RUN, [function_name, version, args])
    end

    # --- Live Queries ---

    # Starts a live query on a table (WebSocket only).
    # @param resource [String, Table] table name
    # @param diff [Boolean] whether to receive diffs instead of full records
    # @return [String] live query UUID
    def live(resource, diff: false)
      require_live_queries!
      @connection.send_request(Protocol::Methods::LIVE, [table_param(resource), diff])
    end

    # Subscribes to live query notifications.
    # @param live_query_id [String] UUID from #live
    # @yield [Hash] notification with :action and :result keys
    # @return [void]
    def subscribe(live_query_id, &block)
      require_live_queries!
      @connection.on_notification(live_query_id.to_s, block)
    end

    # Kills a live query.
    # @param live_query_id [String]
    # @return [void]
    def kill(live_query_id)
      require_live_queries!
      @connection.remove_notification_handler(live_query_id.to_s)
      @connection.send_request(Protocol::Methods::KILL, [live_query_id])
    end

    # --- Import / Export ---

    # Imports SurrealQL data or ML model data into the database.
    # @param content [String] SurrealQL or ML content to import
    # @return [Object]
    def import_data(content)
      @connection.send_request(Protocol::Methods::IMPORT, [content])
    end

    # Exports the database as SurrealQL.
    # @return [String] exported data
    def export_data
      @connection.send_request(Protocol::Methods::EXPORT)
    end

    # --- Info ---

    # Returns the SurrealDB server version.
    # @return [String]
    def version
      @connection.send_request(Protocol::Methods::VERSION)
    end

    # Returns info about the current session.
    # @return [Hash, nil]
    def info
      @connection.send_request(Protocol::Methods::INFO)
    end

    # --- Sessions / Transactions (WebSocket only) ---

    # Attaches a new session to the connection.
    # @return [String] session ID
    def attach
      require_websocket!('sessions')
      @connection.send_request(Protocol::Methods::ATTACH)
    end

    # Detaches a session from the connection.
    # @param session_id [String]
    # @return [void]
    def detach(session_id)
      require_websocket!('sessions')
      @connection.send_request(Protocol::Methods::DETACH, [session_id])
    end

    # Begins a transaction on the current session.
    # @return [void]
    def begin_transaction
      require_websocket!('transactions')
      @connection.send_request(Protocol::Methods::BEGIN_TXN)
    end

    # Commits the current transaction.
    # @return [void]
    def commit
      require_websocket!('transactions')
      @connection.send_request(Protocol::Methods::COMMIT)
    end

    # Cancels (rolls back) the current transaction.
    # @return [void]
    def cancel
      require_websocket!('transactions')
      @connection.send_request(Protocol::Methods::CANCEL)
    end

    # --- Generic RPC ---

    # Sends an arbitrary RPC method call. Useful as an escape hatch for
    # server methods not yet wrapped by the SDK.
    # @param method [String] RPC method name
    # @param params [Array] method parameters
    # @return [Object] decoded result
    def send_rpc(method, params = [])
      @connection.send_request(method, params)
    end

    private

    def build_connection(url, **options)
      uri = URI.parse(url)
      case uri.scheme
      when 'ws', 'wss'
        ws = Connections::WebSocket.new(url, **options)
        options[:reconnect] ? Connections::ReliableWebSocket.new(ws, **options) : ws
      when 'http', 'https'
        Connections::HTTP.new(url, **options)
      when 'mem', 'memory', 'surrealkv', 'file'
        require_embedded!
        Connections::Embedded.new(url, **options)
      else
        raise ArgumentError,
              "unsupported URL scheme: #{uri.scheme}. " \
              'Use ws://, wss://, http://, https://, mem://, surrealkv://, or file://'
      end
    end

    # Table or record target for CRUD methods. Typed values are passed through
    # so the encoder sends them as CBOR tags 7 and 8. Strings are table names.
    def resource_param(resource)
      case resource
      when Table, RecordID, StringRecordID then resource
      else table_param(resource)
      end
    end

    def table_param(resource)
      return resource if resource.is_a?(Table)

      name = resource.to_s
      if name.include?(':')
        raise ArgumentError,
              "#{name.inspect} is not a table name. Strings are never parsed as record ids; " \
              "pass SurrealDB::RecordID.new(table, id), SurrealDB::RecordID.parse(#{name.inspect}) " \
              "or SurrealDB::StringRecordID.new(#{name.inspect})"
      end

      Table.new(name)
    end

    def record_param(record)
      case record
      when RecordID, StringRecordID then record
      when Array then record.map { |r| record_param(r) }
      else
        raise ArgumentError,
              "expected a SurrealDB::RecordID, got #{record.inspect}. Strings are never parsed as record ids; " \
              'use SurrealDB::RecordID.parse or SurrealDB::StringRecordID'
      end
    end

    def require_live_queries!
      return if @connection.supports_live_queries?

      raise UnsupportedError, 'live queries require a WebSocket connection (ws:// or wss://)'
    end

    def require_websocket!(feature)
      return if @connection.supports_live_queries?

      raise UnsupportedError, "#{feature} require a WebSocket connection (ws:// or wss://)"
    end

    def require_embedded!
      return if defined?(Connections::Embedded)

      raise LoadError,
            'embedded connections require the surrealdb-embedded gem. ' \
            'Add `require "surrealdb/embedded"` after `require "surrealdb"`.'
    end
  end
end
