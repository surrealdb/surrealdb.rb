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

    def inspect
      "#<SurrealDB::Transaction #{@id} #{@state}>"
    end

    private

    def finish(method, state)
      raise TransactionError, "transaction #{@id} is already #{@state}" unless open?

      @connection.send_request(method, [@id], session: @session)
      @state = state
      nil
    end

    def rpc(method, params = [], timeout: nil)
      raise TransactionError, "transaction #{@id} is #{@state}" unless open?

      @connection.send_request(method, params, session: @session, txn: @id, **timeout_option(timeout))
    end
  end
end
