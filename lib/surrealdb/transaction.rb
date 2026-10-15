# frozen_string_literal: true

module SurrealDB
  # An interactive transaction.
  #
  # Queries and CRUD calls made through a transaction run inside it, and
  # nothing they write is visible outside it until {#commit}. {#cancel}
  # discards everything. Start one with {RequestMethods#begin_transaction}
  # on a {Client} or a {Session}; the transaction runs in that session.
  #
  # Transactions need a WebSocket connection.
  class Transaction
    include QueryMethods

    # @return [Uuid]
    attr_reader :id

    # @return [Uuid, nil] the session the transaction runs in (nil for the
    #   connection's default session)
    attr_reader :session

    # @return [Connections::Base]
    attr_reader :connection

    # @param connection [Connections::Base]
    # @param id [Uuid]
    # @param session [Uuid, nil]
    def initialize(connection, id, session: nil)
      @connection = connection
      @id = id
      @session = session
      @state = :open
    end

    # Makes the transaction's writes permanent.
    # @return [void]
    def commit
      finish(Protocol::Methods::COMMIT, :committed)
    end

    # Discards the transaction's writes.
    # @return [void]
    def cancel
      finish(Protocol::Methods::CANCEL, :cancelled)
    end
    alias rollback cancel

    # @return [Boolean] whether the transaction can still run requests
    def open?
      @state == :open
    end

    # @return [Boolean]
    def committed?
      @state == :committed
    end

    # @return [Boolean]
    def cancelled?
      @state == :cancelled
    end

    # Whether the connection dropped while the transaction was open, which
    # ends it on the server: nothing in it was committed, unless a commit
    # was in flight, in which case it is not known whether it took effect.
    # @return [Boolean]
    def lost?
      @state == :lost
    end

    def inspect
      "#<SurrealDB::Transaction #{@id} #{@state}>"
    end

    private

    def finish(method, state)
      raise TransactionError, "transaction #{@id} is already #{@state}" unless open?

      request(method, [@id])
      @state = state
      nil
    end

    # The server cancelled the transaction (the session was reset).
    def discard
      @state = :cancelled if open?
    end

    def rpc(method, params = [], timeout: nil)
      raise TransactionError, "transaction #{@id} is #{@state}" unless open?

      request(method, params, txn: @id, **timeout_option(timeout))
    end

    # A transaction does not outlive its connection, so once a request
    # through it is interrupted the transaction is over. One that timed out
    # may still be running on the server, or have committed, so the
    # transaction cannot safely be used after that either; one that timed
    # out before it was sent changed nothing, and the transaction is still
    # open.
    def request(method, params, **)
      @connection.send_request(method, params, session: @session, **)
    rescue RequestInterruptedError
      @state = :lost
      raise
    rescue TimeoutError => e
      @state = :lost if e.sent?
      raise
    end

    def stream_rpc(method, params, timeout, &)
      raise TransactionError, "transaction #{@id} is #{@state}" unless open?

      @connection.stream_request(method, params, session: @session, txn: @id, **timeout_option(timeout), &)
    rescue RequestInterruptedError
      @state = :lost
      raise
    rescue TimeoutError => e
      @state = :lost if e.sent?
      raise
    end
  end
end
