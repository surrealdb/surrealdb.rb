# frozen_string_literal: true

module SurrealDB
  # Query and CRUD request methods: everything that can also run inside an
  # interactive {Transaction}.
  #
  # Includers implement `rpc(method, params)`.
  module QueryMethods
    # JSON-RPC's code for a method the server does not have.
    METHOD_NOT_FOUND = -32_601
    # JSON-RPC's code for a method the server's capabilities deny.
    METHOD_NOT_ALLOWED = -32_602
    # A server older than 3.3 has no `query_stream`; one started with
    # `--deny-rpc query_stream` refuses it before running anything. Either
    # way the query can still run buffered.
    STREAMING_REFUSED = [METHOD_NOT_FOUND, METHOD_NOT_ALLOWED].freeze

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
    # Variables can be given as a Hash or as keywords. `timeout:` is the call
    # timeout, so a variable named `timeout` must go in the Hash.
    #
    # @example
    #   db.query("RETURN 1; SELECT * FROM person") # => [1, [{...}, ...]]
    #   db.query("SELECT * FROM person WHERE age > $min", min: 18)
    # @param sql [String] SurrealQL statement(s)
    # @param vars [Hash] query variables
    # @param timeout [Numeric, nil] seconds to wait for the result (see {#with_timeout})
    # @param named [Hash] more query variables, as keywords
    # @return [Array] one result per statement
    # @raise [ServerError] when a statement fails
    # @raise [TimeoutError] when the result does not arrive in time
    def query(sql, vars = {}, timeout: nil, **named)
      query_raw(sql, vars, timeout: timeout, **named).map do |statement|
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
    # @param named [Hash] more query variables, as keywords (see {#query})
    # @return [Array<QueryResult>]
    def query_raw(sql, vars = {}, timeout: nil, **named)
      statements(Protocol::Methods::QUERY, sql, vars.merge(named), timeout)
    end

    # Runs an ISO GQL (ISO/IEC 39075) query and returns each statement's
    # result, raising the first failed statement's error, as {#query} does.
    # A namespace and database must be selected.
    #
    # @example
    #   db.gql("MATCH (p:person) WHERE p.age > $min RETURN p.name AS name", { "min" => 30 })
    #   # => [[{ "name" => "Alice" }]]
    # @param query [String] GQL statement(s)
    # @param vars [Hash] query variables
    # @param timeout [Numeric, nil] seconds to wait for the result
    # @param named [Hash] more query variables, as keywords (see {#query})
    # @return [Array] one result per statement
    # @raise [UnsupportedError] when the server has no GQL support
    # @raise [ServerError] when a statement fails
    def gql(query, vars = {}, timeout: nil, **named)
      statements(Protocol::Methods::GQL, query, vars.merge(named), timeout).map do |statement|
        raise statement.to_error if statement.error?

        statement.result
      end
    rescue NotFoundError => e
      raise unless e.code == METHOD_NOT_FOUND

      raise UnsupportedError, 'this SurrealDB server does not support GQL queries'
    end

    # A client for the server's user-defined APIs (`DEFINE API`), invoked
    # through `api::invoke` in this session (and transaction).
    #
    # @example
    #   users = db.api("/users")
    #   users.header("x-tenant", "acme")
    #   users.get("/42").value     # => the response body, raising ApiError unless 2xx
    #   users.post("", { "name" => "Ann" }).status
    # @param prefix [String] prepended to every path
    # @return [Api]
    def api(prefix = '')
      Api.new(self, prefix)
    end

    # Runs a SurrealQL query and yields its results as the server produces
    # them, instead of holding every row in memory until the query is done.
    #
    # Each statement's result arrives as {QueryChunk}s: `:rows` chunks for a
    # statement that returns rows, a `:value` chunk for one that returns a
    # single value, then a `:finished` chunk with its time and any error.
    # After the last chunk, the first failed statement's error is raised, as
    # {#query} does; rows a failed statement sent before failing are not
    # valid.
    #
    # Streaming needs a WebSocket connection and a server with
    # `query_stream` (SurrealDB 3.3 and later). Elsewhere the query runs
    # buffered and its results are yielded as the same chunks. Leaving the
    # block early stops the query on the server.
    #
    # @example
    #   db.query_stream("SELECT * FROM event") do |chunk|
    #     chunk.values.each { |row| handle(row) } if chunk.rows?
    #   end
    # @param sql [String] SurrealQL statement(s)
    # @param vars [Hash] query variables
    # @param timeout [Numeric, nil] seconds to wait for each chunk
    # @param named [Hash] more query variables, as keywords (see {#query})
    # @yield [QueryChunk]
    # @return [Enumerator, nil] an Enumerator of chunks without a block
    # @raise [ServerError] when a statement fails, after its chunks are yielded
    def query_stream(sql, vars = {}, timeout: nil, **named, &block)
      return enum_for(:query_stream, sql, vars, timeout: timeout, **named) unless block

      vars = vars.merge(named) unless named.empty?

      errors = []
      each_query_chunk(sql, vars, timeout) do |chunk|
        errors << chunk.error if chunk.error?
        block.call(chunk)
      end
      raise errors.first unless errors.empty?
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

    def statements(method, sql, vars, timeout)
      params = [sql]
      params << vars unless vars.empty?
      raw = rpc(method, params, timeout: timeout)
      Array(raw).map { |stmt| QueryResult.from_response(stmt) }
    end

    # Streams when the connection and server can, and otherwise runs the
    # query buffered and yields the same chunks.
    def each_query_chunk(sql, vars, timeout, &)
      return if connection.supports_streaming? && stream_query_chunks(sql, vars, timeout, &)

      QueryChunk.from_results(query_raw(sql, vars, timeout: timeout)).each(&)
    end

    # @return [Boolean] false when the server does not offer streaming
    def stream_query_chunks(sql, vars, timeout, &block)
      params = [sql]
      params << vars unless vars.empty?
      started = false
      with_result = {} # statements that sent a rows or value frame
      stream_rpc(Protocol::Methods::QUERY_STREAM, params, timeout) do |frame|
        started = true
        raise_stream_failure(frame)
        chunk = QueryChunk.from_frame(frame)
        with_implied_result(chunk, with_result, &block) if chunk
      end
      true
    rescue NotFoundError, NotAllowedError => e
      raise if started || !STREAMING_REFUSED.include?(e.code)

      connection.streaming_unavailable!
      false
    end

    # A statement whose result is an empty list (or, with `single`, NONE)
    # sends no rows or value frame; yield the chunk a buffered result would
    # have had for it before its :finished chunk.
    def with_implied_result(chunk, with_result)
      if !chunk.finished?
        with_result[chunk.index] = true
      elsif !chunk.error? && !with_result[chunk.index]
        yield QueryChunk.implied_by(chunk)
      end
      yield chunk
    end

    # A stream the server stopped (cancelled, or that failed as a whole)
    # carries the reason on its `end` frame.
    def raise_stream_failure(frame)
      error = frame['error']
      return unless frame['stream'] == 'end' && !error.nil? && !error.is_a?(None)

      raise error.is_a?(Hash) ? ServerError.from_response(error) : ServerError.new(error.to_s)
    end

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
