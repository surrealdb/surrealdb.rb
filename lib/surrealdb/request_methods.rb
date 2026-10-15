# frozen_string_literal: true

module SurrealDB
  # Request methods shared by everything that runs requests in a server
  # session: the {Client} (the connection's default session) and each
  # attached {Session}.
  #
  # Includers implement `rpc(method, params)` and `connection`.
  module RequestMethods
    # --- Namespace / Database ---

    # Selects the namespace and database to use.
    # @param namespace [String]
    # @param database [String]
    # @return [void]
    def use(namespace, database)
      rpc(Protocol::Methods::USE, [namespace, database])
    end

    # --- Authentication ---

    # Signs in to SurrealDB.
    # @param credentials [Hash] authentication credentials (string keys)
    # @return [String, Hash] JWT token or tokens hash
    def signin(credentials = {})
      rpc(Protocol::Methods::SIGNIN, [credentials])
    end

    # Signs up a new user.
    # @param credentials [Hash] signup credentials (string keys)
    # @return [String, Hash] JWT token or tokens hash
    def signup(credentials = {})
      rpc(Protocol::Methods::SIGNUP, [credentials])
    end

    # Authenticates with an existing JWT token.
    # @param token [String]
    # @return [void]
    def authenticate(token)
      rpc(Protocol::Methods::AUTHENTICATE, [token])
    end

    # Invalidates the current session.
    # @return [void]
    def invalidate
      rpc(Protocol::Methods::INVALIDATE)
    end

    # --- Variables ---

    # Sets a session variable, available to later queries as $key.
    # @param key [String]
    # @param value [Object]
    # @return [void]
    def set(key, value)
      rpc(Protocol::Methods::LET, [key, value])
    end
    alias let set

    # Removes a session variable.
    # @param key [String]
    # @return [void]
    def unset(key)
      rpc(Protocol::Methods::UNSET, [key])
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
      rpc(Protocol::Methods::SELECT, [resource_param(resource)])
    end

    # Creates a new record.
    # @param resource [String, Table, RecordID, StringRecordID] table name or record id
    # @param data [Hash, nil] record content
    # @return [Hash] created record
    def create(resource, data = nil)
      params = [resource_param(resource)]
      params << data unless data.nil?
      rpc(Protocol::Methods::CREATE, params)
    end

    # Inserts one or more records into a table.
    # @param table [String, Table] table name
    # @param data [Hash, Array<Hash>] record(s) to insert
    # @return [Array] inserted records
    def insert(table, data)
      rpc(Protocol::Methods::INSERT, [table_param(table), data])
    end

    # Inserts a relation record.
    # @param table [String, Table] relation table name
    # @param data [Hash] relation data (must include :in and :out)
    # @return [Array] inserted relation records
    def insert_relation(table, data)
      rpc(Protocol::Methods::INSERT_RELATION, [table_param(table), data])
    end

    # Replaces a record or all records in a table.
    # @param resource [String, Table, RecordID, StringRecordID] table name or record id
    # @param data [Hash] replacement content
    # @return [Object] updated record(s)
    def update(resource, data)
      rpc(Protocol::Methods::UPDATE, [resource_param(resource), data])
    end

    # Upserts a record (insert or update).
    # @param resource [String, Table, RecordID, StringRecordID] table name or record id
    # @param data [Hash] record content
    # @return [Object] upserted record(s)
    def upsert(resource, data)
      rpc(Protocol::Methods::UPSERT, [resource_param(resource), data])
    end

    # Deep-merges data into a record.
    # @param resource [String, Table, RecordID, StringRecordID] table name or record id
    # @param data [Hash] data to merge
    # @return [Object] merged record(s)
    def merge(resource, data)
      rpc(Protocol::Methods::MERGE, [resource_param(resource), data])
    end

    # Applies JSON Patch operations to a record.
    # @param resource [String, Table, RecordID, StringRecordID] table name or record id
    # @param patches [Array<Hash>] patch operations
    # @return [Object] patched record(s)
    def patch(resource, patches)
      rpc(Protocol::Methods::PATCH, [resource_param(resource), patches])
    end

    # Deletes a record or all records from a table.
    # @param resource [String, Table, RecordID, StringRecordID] table name or record id
    # @return [Object] deleted record(s)
    def delete(resource)
      rpc(Protocol::Methods::DELETE, [resource_param(resource)])
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
      rpc(Protocol::Methods::RELATE, params)
    end

    # --- Query ---

    # Executes a SurrealQL query.
    # @param sql [String] SurrealQL statement(s)
    # @param vars [Hash] query variables
    # @return [Array] array of result sets (one per statement)
    def query(sql, vars = {})
      params = [sql]
      params << vars unless vars.empty?
      rpc(Protocol::Methods::QUERY, params)
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
      raw = rpc(Protocol::Methods::QUERY, params)
      Array(raw).map { |stmt| QueryResult.from_response(stmt) }
    end

    # Runs a SurrealDB function.
    # @param function_name [String]
    # @param args [Array] function arguments
    # @param version [String, nil] optional function version
    # @return [Object]
    def run(function_name, *args, version: nil)
      rpc(Protocol::Methods::RUN, [function_name, version, args])
    end

    # --- Live Queries ---

    # Starts a live query on a table (WebSocket only).
    # @param resource [String, Table] table name
    # @param diff [Boolean] whether to receive diffs instead of full records
    # @return [String] live query UUID
    def live(resource, diff: false)
      require_live_queries!
      rpc(Protocol::Methods::LIVE, [table_param(resource), diff])
    end

    # Subscribes to live query notifications.
    # @param live_query_id [String] UUID from #live
    # @yield [Hash] notification with :action and :result keys
    # @return [void]
    def subscribe(live_query_id, &block)
      require_live_queries!
      connection.on_notification(live_query_id.to_s, block)
    end

    # Kills a live query.
    # @param live_query_id [String]
    # @return [void]
    def kill(live_query_id)
      require_live_queries!
      connection.remove_notification_handler(live_query_id.to_s)
      rpc(Protocol::Methods::KILL, [live_query_id])
    end

    # --- Transactions (WebSocket only) ---

    # Begins a transaction in this session.
    # @return [void]
    def begin_transaction
      require_transactions!
      rpc(Protocol::Methods::BEGIN_TXN)
    end

    # Commits the current transaction.
    # @return [void]
    def commit
      require_transactions!
      rpc(Protocol::Methods::COMMIT)
    end

    # Cancels (rolls back) the current transaction.
    # @return [void]
    def cancel
      require_transactions!
      rpc(Protocol::Methods::CANCEL)
    end

    # --- Info ---

    # Returns info about the current session.
    # @return [Hash, nil]
    def info
      rpc(Protocol::Methods::INFO)
    end

    private

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

    def require_transactions!
      return if connection.supports_live_queries?

      raise UnsupportedError, 'transactions require a WebSocket connection (ws:// or wss://)'
    end

    def require_live_queries!
      return if connection.supports_live_queries?

      raise UnsupportedError, 'live queries require a WebSocket connection (ws:// or wss://)'
    end
  end
end
