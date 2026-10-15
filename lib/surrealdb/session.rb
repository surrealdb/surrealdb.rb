# frozen_string_literal: true

module SurrealDB
  # A server session attached on a connection.
  #
  # A session has its own namespace, database, variables and credentials,
  # and every request made through it runs in it. Several sessions can share
  # one connection, which is how one client serves several users or tenants
  # at once. Create one with {Client#new_session} or {Client#fork_session}.
  #
  # Sessions work over WebSocket and HTTP. Over HTTP the server keeps the
  # session between requests, and listing sessions is not allowed.
  class Session
    include RequestMethods

    # @return [Uuid]
    attr_reader :id

    # @return [Client]
    attr_reader :client

    # @param client [Client]
    # @param id [Uuid]
    def initialize(client, id)
      @client = client
      @id = id
      @closed = false
    end

    # The connection the session lives on.
    # @return [Connections::Base]
    def connection
      @client.connection
    end

    # Attaches a new session starting from a copy of this one's state.
    # @yield [Session] optional; the fork is detached when the block returns
    # @return [Session]
    def fork_session(&)
      @client.fork_session(self, &)
    end

    # Detaches the session, discarding its server-side state.
    # @return [void]
    def close
      @client.detach(self)
    end
    alias detach close

    # @return [Boolean]
    def closed?
      @closed
    end

    def inspect
      "#<SurrealDB::Session #{@id}#{' closed' if @closed}>"
    end

    private

    def request_session
      @id
    end

    # Called by {Client#detach} once the server has detached the session.
    def detached!
      @closed = true
    end

    def rpc(method, params = [])
      raise SessionError, "session #{@id} is closed" if @closed

      connection.send_request(method, params, session: @id)
    end
  end
end
