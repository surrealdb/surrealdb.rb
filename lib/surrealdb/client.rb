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
    include RequestMethods

    # @return [Connections::Base]
    attr_reader :connection

    # @param url [String] connection URL (ws://, wss://, http://, https://)
    # @param options [Hash] connection options
    # @option options [Numeric] :timeout response timeout in seconds
    # @option options [Numeric] :connect_timeout WebSocket connect deadline (defaults to :timeout)
    # @option options [Boolean] :reconnect reconnect WebSocket connections automatically (default true)
    # @option options [Integer] :reconnect_max_retries reconnection attempts before giving up (default 5)
    # @option options [Numeric] :reconnect_delay base backoff delay in seconds (default 1.0)
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

    # --- Info ---

    # Returns the SurrealDB server version.
    # @return [String]
    def version
      @connection.send_request(Protocol::Methods::VERSION)
    end

    # --- Sessions ---

    # Attaches a new server session on this connection.
    #
    # The session starts empty: no namespace, database, variables or
    # credentials. Requests made through the returned {Session} run in it,
    # independently of the client's default session and of other sessions.
    #
    # With a block, the session is detached when the block returns.
    #
    # @yield [Session] optional
    # @return [Session]
    # @example
    #   client.new_session do |session|
    #     session.use("app", "tenant_a")
    #     session.signin("user" => "alice", "pass" => "secret", "ns" => "app")
    #     session.select("invoice")
    #   end
    def new_session(&)
      require_sessions!
      id = Uuid.v4
      @connection.send_request(Protocol::Methods::ATTACH, [], session: id)
      with_session(Session.new(self, id), &)
    end
    alias attach new_session

    # Attaches a new session that starts with a copy of another session's
    # namespace, database, variables and credentials.
    #
    # @param from [Session, nil] the session to copy; nil copies the
    #   client's default session
    # @yield [Session] optional; the fork is detached when the block returns
    # @return [Session]
    def fork_session(from = nil, &)
      state = @connection.session_state(from && session_id(from))
      raise ArgumentError, "unknown session: #{from.inspect}" unless state

      session = new_session
      begin
        restore_state(session, state.copy)
      rescue StandardError
        session.close
        raise
      end
      with_session(session, &)
    end

    # Detaches a session, discarding its server-side state. A {Session}
    # passed here is closed, so later requests through it raise
    # {SessionError} instead of reaching the server.
    # @param session [Session, Uuid, String]
    # @return [void]
    def detach(session)
      require_sessions!
      return if session.is_a?(Session) && session.closed?

      @connection.send_request(Protocol::Methods::DETACH, [], session: session_id(session))
      session.send(:detached!) if session.is_a?(Session)
      nil
    end

    # Lists the ids of the sessions attached on this connection.
    # @return [Array<Uuid>]
    # @raise [UnsupportedError] over HTTP, where the server refuses it
    def sessions
      require_sessions!
      unless @connection.supports_session_listing?
        raise UnsupportedError, "listing sessions is not supported by #{@connection.class.name}"
      end

      @connection.send_request(Protocol::Methods::SESSIONS)
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

    # Requests made directly on the client run in the connection's default
    # session.
    def rpc(method, params = [])
      @connection.send_request(method, params)
    end

    def request_session
      nil
    end

    def restore_state(session, state)
      session.use(state.namespace, state.database) if state.namespace || state.database
      state.variables.each { |key, value| session.set(key, value) }
      session.authenticate(state.access_token) if state.access_token
    end

    def with_session(session)
      return session unless block_given?

      begin
        yield session
      ensure
        session.close unless session.closed?
      end
    end

    def session_id(session)
      case session
      when Session then session.id
      when Uuid then session
      else Uuid.parse(session.to_s)
      end
    end

    def require_sessions!
      return if @connection.supports_sessions?

      raise UnsupportedError, "sessions are not supported by #{@connection.class.name}"
    end

    def build_connection(url, **options)
      uri = URI.parse(url)
      case uri.scheme
      when 'ws', 'wss'
        ws = Connections::WebSocket.new(url, **options)
        options.fetch(:reconnect, true) ? Connections::ReliableWebSocket.new(ws, **options) : ws
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

    def require_embedded!
      return if defined?(Connections::Embedded)

      raise LoadError,
            'embedded connections require the surrealdb-embedded gem. ' \
            'Add `require "surrealdb/embedded"` after `require "surrealdb"`.'
    end
  end
end
