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

    # @return [String, nil] the server's version, as it reported it on connect
    attr_reader :server_version

    # @param url [String] connection URL (ws://, wss://, http://, https://)
    # @param options [Hash] connection options
    # @option options [Numeric, nil] :timeout seconds to wait for a response (default: none, wait
    #   as long as the server takes; see {Configuration#timeout})
    # @option options [Numeric] :connect_timeout WebSocket connect deadline (defaults to :timeout,
    #   or 30 seconds without one)
    # @option options [Boolean] :reconnect reconnect WebSocket connections automatically (default true)
    # @option options [Integer] :reconnect_max_retries reconnection attempts before giving up (default 5)
    # @option options [Numeric] :reconnect_delay base backoff delay in seconds (default 1.0)
    # @option options [Boolean] :version_check refuse servers outside {ServerVersion} (default true)
    # @option options [Boolean] :renew_tokens renew access tokens before they expire (default true)
    # @option options [Numeric] :token_refresh_margin seconds before expiry to renew (default 60)
    def initialize(url, **options)
      @url = url
      @options = options
      @version_check = options.fetch(:version_check, true)
      @server_version = nil
      @connection = build_connection(url, **options)
      # A reconnect may reach another server (a rolling upgrade, a failover).
      @connection.on_reconnect { |fresh| check_server_version(fresh) } if @connection.respond_to?(:on_reconnect)
    end

    # Opens the connection to SurrealDB and checks the server's version.
    # @return [self]
    # @raise [UnsupportedVersionError] when the server's version is not supported
    #   (the connection is closed again)
    def connect
      @connection.connect
      begin
        check_server_version
      rescue StandardError
        # Whatever went wrong, the caller gets no usable client back, so the
        # transport must not be left open.
        close_quietly
        raise
      end
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

    # Checks that the server is up and its storage reachable, through its
    # HTTP /health route (for embedded connections: that the engine is open).
    # @return [void]
    # @raise [ServerError] when the server reports itself unhealthy
    # @raise [ConnectionError] when it cannot be reached
    def health
      @connection.health
      nil
    end

    # Like {#health}, but answers true or false instead of raising.
    # @return [Boolean]
    def healthy?
      health
      true
    rescue Error
      false
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

    private

    # Asks the server for its version, on the given connection (a reconnect
    # checks the new one before anything is restored on it).
    def check_server_version(connection = @connection)
      @server_version = connection.send_request(Protocol::Methods::VERSION).to_s
      ServerVersion.check!(@server_version) if @version_check
    end

    def close_quietly
      @connection.close
    rescue StandardError => e
      SurrealDB.configuration.logger&.debug("Closing after a failed connect also failed: #{e.message}")
    end

    # Requests made directly on the client run in the connection's default
    # session.
    def rpc(method, params = [], timeout: nil)
      @connection.send_request(method, params, **timeout_option(timeout))
    end

    def stream_rpc(method, params, timeout, &)
      @connection.stream_request(method, params, **timeout_option(timeout), &)
    end

    def request_session
      nil
    end

    # The fork gets the credentials to renew its token as well as the token:
    # the refresh token, and what the original last signed in with.
    def restore_state(session, state)
      session.use(state.namespace, state.database) if state.namespace || state.database
      state.variables.each { |key, value| session.set(key, value) }
      return unless state.access_token

      session.authenticate(state.tokens)
      @connection.session_state(session.id)&.signin = state.signin
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
