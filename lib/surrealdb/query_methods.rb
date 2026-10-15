# frozen_string_literal: true

module SurrealDB
  # Query and CRUD request methods: everything that can also run inside an
  # interactive {Transaction}.
  #
  # Includers implement `rpc(method, params)`.
  module QueryMethods
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

    # Executes a SurrealQL query and returns each statement's result.
    #
    # If any statement fails, raises that statement's error (the first, if
    # several fail), as the {ServerError} subclass matching its kind. Use
    # {#query_raw} to see every statement's outcome, including the ones that
    # succeeded alongside a failure.
    #
    # @example
    #   db.query("RETURN 1; SELECT * FROM person") # => [1, [{...}, ...]]
    # @param sql [String] SurrealQL statement(s)
    # @param vars [Hash] query variables
    # @param timeout [Numeric, nil] seconds to wait for the result (see {#with_timeout})
    # @return [Array] one result per statement
    # @raise [ServerError] when a statement fails
    # @raise [TimeoutError] when the result does not arrive in time
    def query(sql, vars = {}, timeout: nil)
      query_raw(sql, vars, timeout: timeout).map do |statement|
        raise statement.to_error if statement.error?

        statement.result
      end
    end

    # Executes a SurrealQL query and returns structured per-statement results.
    # Unlike {#query}, this returns {QueryResult} objects with status, timing,
    # and per-statement error information, and does not raise when a
    # statement fails.
    # @param sql [String] SurrealQL statement(s)
    # @param vars [Hash] query variables
    # @param timeout [Numeric, nil] seconds to wait for the result (see {#with_timeout})
    # @return [Array<QueryResult>]
    def query_raw(sql, vars = {}, timeout: nil)
      params = [sql]
      params << vars unless vars.empty?
      raw = rpc(Protocol::Methods::QUERY, params, timeout: timeout)
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

    # Runs the block with a different response timeout for every request it
    # makes on this connection, including through its sessions and
    # transactions. Nested calls use the innermost timeout.
    #
    # The timeout is how long the client waits: a request that times out
    # raises {TimeoutError}, but the server may still finish running it. To
    # stop a statement on the server, give it a `TIMEOUT` clause. Embedded
    # connections ignore it and use the engine's query timeout.
    #
    # @example
    #   db.with_timeout(2) { db.select("person") }
    # @param seconds [Numeric]
    # @return [Object] the block's value
    def with_timeout(seconds)
      raise ArgumentError, "timeout must be positive, got #{seconds.inspect}" unless seconds.is_a?(Numeric) &&
                                                                                     seconds.positive?

      timeouts = (Thread.current[:surrealdb_call_timeouts] ||= {}.compare_by_identity)
      previous = timeouts[connection]
      timeouts[connection] = seconds
      begin
        yield
      ensure
        previous.nil? ? timeouts.delete(connection) : timeouts[connection] = previous
      end
    end

    private

    # The `timeout:` option for a request: the one given for the call, else
    # the one {#with_timeout} set for this connection in this fiber, else
    # none (the connection's own timeout applies).
    def timeout_option(timeout)
      timeout ||= Thread.current[:surrealdb_call_timeouts]&.[](connection)
      timeout ? { timeout: timeout } : {}
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
  end
end
