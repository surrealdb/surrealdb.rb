# frozen_string_literal: true

module SurrealDB
  # Request methods shared by everything that runs requests in a server
  # session: the {Client} (the connection's default session) and each
  # attached {Session}. Adds session-level methods (namespace, auth,
  # variables, live queries, transactions) to {QueryMethods}.
  #
  # Includers implement `rpc(method, params)` and `connection`.
  module RequestMethods
    include QueryMethods

    # Keeps at most this many import failures on an {ImportError}.
    KEPT_IMPORT_FAILURES = 100

    # --- Namespace / Database ---

    # Selects the namespace and database to use.
    #
    # Either can be left as it is or cleared: a String selects it, `nil`
    # clears it, and {SurrealDB::NONE} (the default) leaves it unchanged.
    # A database needs a namespace, so clearing the namespace clears the
    # database too.
    #
    # @example
    #   db.use("app", "prod")       # both
    #   db.use("app")               # namespace only; the database is unchanged
    #   db.use(database: "staging") # database only
    #   db.use(database: nil)       # clear the database
    #   db.use(namespace: nil)      # clear both
    # @param ns [String, nil, None] namespace
    # @param db [String, nil, None] database
    # @param namespace [String, nil, None] namespace, as a keyword
    # @param database [String, nil, None] database, as a keyword
    # @return [Hash{String => String, nil}] the resulting "namespace" and "database"
    # @raise [ArgumentError] when clearing the namespace but selecting a database
    def use(ns = NONE, db = NONE, namespace: ns, database: db)
      if namespace.nil?
        raise ArgumentError, 'cannot select a database without a namespace' if database.is_a?(String)

        database = nil
      end
      result = rpc(Protocol::Methods::USE, [namespace, database])
      state = request_state
      { 'namespace' => state&.namespace, 'database' => state&.database }.tap do |current|
        next unless result.is_a?(Hash)

        current['namespace'] = present(result['namespace'])
        current['database'] = present(result['database'])
      end
    end

    # Resets the session to how it was when it was opened: signs out, clears
    # the namespace, database and variables, kills its live queries and
    # cancels its open transactions.
    # @return [void]
    def reset
      rpc(Protocol::Methods::RESET, [])
      live_query_ids.each { |id| connection.remove_notification_handler(id) }
      live_query_ids.clear
      open_transactions.each { |txn| txn.send(:discard) }
      open_transactions.clear
      nil
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

    # --- Live Queries ---

    # Starts a live query on a table (WebSocket only).
    # @param resource [String, Table] table name
    # @param diff [Boolean] whether to receive diffs instead of full records
    # @return [String] live query UUID
    def live(resource, diff: false)
      require_live_queries!
      rpc(Protocol::Methods::LIVE, [table_param(resource), diff]).tap { |id| live_query_ids << id.to_s }
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
      live_query_ids.delete(live_query_id.to_s)
      rpc(Protocol::Methods::KILL, [live_query_id])
    end

    # --- Transactions ---

    # Begins an interactive transaction in this session.
    #
    # Without a block, returns the {Transaction}; call {Transaction#commit}
    # or {Transaction#cancel} when done. With a block, yields it, commits
    # when the block returns normally, and returns the block's value; if the
    # block raises or leaves early (`return`, `break`, `throw`), cancels.
    #
    # @yield [Transaction] optional
    # @return [Transaction, Object]
    # @example
    #   client.begin_transaction do |tx|
    #     tx.create(SurrealDB::RecordID.new("account", "a"), { "balance" => 100 })
    #     tx.query("UPDATE account:b SET balance += 100")
    #   end
    def begin_transaction
      require_transactions!
      id = rpc(Protocol::Methods::BEGIN_TXN)
      txn = Transaction.new(connection, id, session: request_session)
      open_transactions.keep_if(&:open?) << txn
      return txn unless block_given?

      run_transaction(txn) { yield txn }
    end
    alias transaction begin_transaction

    # Commits a transaction by object or id.
    # @param txn [Transaction, Uuid]
    # @return [void]
    # @raise [UnsupportedError] on connections without transactions (HTTP)
    def commit(txn)
      return txn.commit if txn.is_a?(Transaction)

      require_transactions!
      rpc(Protocol::Methods::COMMIT, [txn])
      nil
    end

    # Cancels a transaction by object or id.
    # @param txn [Transaction, Uuid]
    # @return [void]
    # @raise [UnsupportedError] on connections without transactions (HTTP)
    def cancel(txn)
      return txn.cancel if txn.is_a?(Transaction)

      require_transactions!
      rpc(Protocol::Methods::CANCEL, [txn])
      nil
    end

    # --- Import / Export ---

    # Imports SurrealQL into the current namespace and database, through the
    # server's HTTP /import route (there is no RPC method for it). Runs with
    # this session's namespace, database and credentials.
    #
    # The content must start with `OPTION IMPORT;`, as exports do; the server
    # refuses anything else. An import is not atomic: statements before a
    # failure stay applied.
    #
    # @param content [String, IO] SurrealQL, or an IO to stream it from
    # @return [void]
    # @raise [ImportError] if any statement failed
    # @raise [ServerError] if the server refused the import
    def import(content)
      response = connection.http_request(
        :post, '/import',
        session: request_session,
        body: content,
        headers: { 'Content-Type' => 'text/plain', 'Accept' => 'application/cbor' }
      )
      raise_import_failures(response)
      nil
    end
    alias import_data import

    # Exports the current database as SurrealQL, through the server's HTTP
    # /export route. Runs with this session's namespace, database and
    # credentials.
    #
    # Options select what is exported, e.g. `tables: ["person"]`,
    # `records: false`, `users: false`, `versions: true`. Omitted options
    # take the server's defaults.
    #
    # @param options [Hash] export configuration
    # @yield [String] chunks of the export as they arrive, when given
    # @return [String, nil] the export, or nil when streamed to a block
    def export(**options, &block)
      verb, body, headers = if options.empty?
                              [:get, nil, {}]
                            else
                              [:post, ::CBOR.encode(CBOR::Encoder.prepare(options.transform_keys(&:to_s))),
                               { 'Content-Type' => 'application/cbor' }]
                            end
      response = connection.http_request(
        verb, '/export',
        session: request_session, body: body, headers: headers.merge('Accept' => 'text/plain'), &block
      )
      Connections::HTTPEndpoint.raise_for(response, 'export') unless response.is_a?(Net::HTTPSuccess)
      block ? nil : response.body.to_s.dup.force_encoding(Encoding::UTF_8)
    end
    alias export_data export

    # --- Info ---

    # Returns info about the current session.
    # @return [Hash, nil]
    def info
      rpc(Protocol::Methods::INFO)
    end

    private

    # Live queries started with {#live} in this session, which {#reset} kills.
    def live_query_ids
      @live_query_ids ||= []
    end

    # Transactions begun in this session that may still be open, which
    # {#reset} cancels.
    def open_transactions
      @open_transactions ||= []
    end

    def present(value)
      value.is_a?(None) ? nil : value
    end

    def request_state
      connection.session_state(request_session)
    end

    # Servers from 3.1 answer a failed import with 422 and only the failed
    # statements; older ones answer 200 with every statement's result. Both
    # are read the same way: whatever came back with status ERR failed.
    def raise_import_failures(response)
      ok = response.is_a?(Net::HTTPSuccess)
      return Connections::HTTPEndpoint.raise_for(response, 'import') unless ok || response.code == '422'

      failures = import_failures(response.body.to_s, ok)
      if failures.any?
        errors = failures.first(KEPT_IMPORT_FAILURES).map { |f| QueryResult.from_response(f).to_error }
        raise ImportError.new(errors, failures.length)
      end
      Connections::HTTPEndpoint.raise_for(response, 'import') unless ok
    end

    # An answer to a successful import that is not a list of statement
    # results cannot show that every statement succeeded, so it is an error
    # rather than an empty list.
    def import_failures(body, succeeded)
      results = begin
        CBOR::Decoder.decode(body)
      rescue StandardError => e
        raise ProtocolError, "could not read the import's result (#{e.class}: #{e.message})" if succeeded
      end
      unless results.is_a?(Array) && results.all?(Hash)
        raise ProtocolError, "the import's result is not a list of statement results" if succeeded

        return []
      end
      results.select { |r| r['status'] == 'ERR' }
    end

    # Commits after the block returns normally. Anything else (an exception,
    # or `return`/`break`/`throw` leaving the block) skips the commit, so the
    # transaction is still open here and is cancelled.
    def run_transaction(txn)
      result = yield
      txn.commit
      result
    ensure
      if txn.open?
        begin
          txn.cancel
        rescue Error => e
          SurrealDB.configuration.logger&.warn("Failed to cancel transaction #{txn.id}: #{e.message}")
        end
      end
    end

    def require_transactions!
      return if connection.supports_transactions?

      raise UnsupportedError, 'transactions require a WebSocket connection (ws:// or wss://)'
    end

    def require_live_queries!
      return if connection.supports_live_queries?

      raise UnsupportedError, 'live queries require a WebSocket connection (ws:// or wss://)'
    end
  end
end
