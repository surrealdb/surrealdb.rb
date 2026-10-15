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

    # --- Info ---

    # Returns info about the current session.
    # @return [Hash, nil]
    def info
      rpc(Protocol::Methods::INFO)
    end

    # --- Generic RPC ---

    # Sends an arbitrary RPC method call. Useful as an escape hatch for
    # server methods not yet wrapped by the SDK. On a {Session} it runs in
    # that session.
    # @param method [String] RPC method name
    # @param params [Array] method parameters
    # @return [Object] decoded result
    def send_rpc(method, params = [])
      rpc(method, params)
    end

    private

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
