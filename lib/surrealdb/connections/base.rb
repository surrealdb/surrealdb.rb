# frozen_string_literal: true

module SurrealDB
  module Connections
    # Abstract base class for SurrealDB transport connections.
    # Subclasses must implement #connect, #close, and #execute.
    class Base
      # Requests that must not trigger a token renewal: they authenticate the
      # session themselves, or do not need it.
      NO_RENEWAL = [
        Protocol::Methods::SIGNIN, Protocol::Methods::SIGNUP, Protocol::Methods::AUTHENTICATE,
        Protocol::Methods::INVALIDATE, Protocol::Methods::REFRESH, Protocol::Methods::REVOKE,
        Protocol::Methods::RESET, Protocol::Methods::ATTACH, Protocol::Methods::DETACH,
        Protocol::Methods::PING, Protocol::Methods::VERSION
      ].freeze

      # @return [String] base URL
      attr_reader :url

      # @return [Protocol::RPC]
      attr_reader :rpc

      def initialize(url, **options)
        @url = url
        @http_timeout = options.fetch(:timeout, SurrealDB.configuration.timeout)
        @rpc = Protocol::RPC.new
        @connected = false
        @state_mutex = Mutex.new
        @session_states = { nil => SessionState.new }
        @renew_tokens = options.fetch(:renew_tokens, true)
        @token_refresh_margin = options.fetch(:token_refresh_margin, 60)
        @renew_mutex = Mutex.new
      end

      # Opens the transport connection.
      # @return [void]
      def connect
        raise NotImplementedError
      end

      # Closes the transport connection.
      # @return [void]
      def close
        raise NotImplementedError
      end

      # Sends an RPC method call and returns the result.
      # @param method [String] RPC method name
      # @param params [Array] method parameters
      # @param session [Uuid, nil] attached session to run the request in
      # @param txn [Uuid, nil] transaction to run the request in
      # @return [Object] decoded result
      def send_request(method, params = [], session: nil, txn: nil)
        renew_before(method, session) unless NO_RENEWAL.include?(method)
        result = execute(method, params, session: session, txn: txn)
        track_request(method, params, result, session)
        result
      end

      # @return [Boolean]
      def connected?
        @connected
      end

      # Whether this connection supports live queries.
      # @return [Boolean]
      def supports_live_queries?
        false
      end

      # Whether this connection supports attached sessions. The server keeps
      # attached sessions for WebSocket and HTTP alike.
      # @return [Boolean]
      def supports_sessions?
        true
      end

      # Whether this connection supports interactive transactions.
      # @return [Boolean]
      def supports_transactions?
        true
      end

      # The server's plain HTTP routes (/import, /export, /health).
      # @return [HTTPEndpoint]
      def http_endpoint
        @http_endpoint ||= HTTPEndpoint.new(@url, timeout: @http_timeout)
      end

      # Sends a request to one of the server's HTTP routes (/import, /export)
      # with a session's namespace, database and credentials, renewing its
      # access token first as {#send_request} does. Like RPC requests, it is
      # refused once the connection has been closed.
      # @param session [Uuid, nil]
      # @return [Net::HTTPResponse]
      # @raise [NotConnectedError] if the connection is not open
      def http_request(verb, path, session: nil, **, &)
        raise NotConnectedError, 'not connected' unless @connected

        renew_before(path, session)
        http_endpoint.request(verb, path, state: session_state(session), **, &)
      end

      # Asks the server's HTTP /health route whether it is up and its storage
      # is reachable.
      # @return [void]
      # @raise [ServerError] when the server reports itself unhealthy
      # @raise [ConnectionError] when it cannot be reached
      def health
        response = http_endpoint.request(:get, '/health')
        HTTPEndpoint.raise_for(response, 'health check') unless response.is_a?(Net::HTTPSuccess)
        nil
      end

      # Whether the server answers `sessions` (listing attached sessions) on
      # this connection.
      # @return [Boolean]
      def supports_session_listing?
        true
      end

      # What the client has told a session so far.
      # @param session [Uuid, nil] nil for the default session
      # @return [SessionState, nil]
      def session_state(session = nil)
        @state_mutex.synchronize { @session_states[session] }
      end

      # The sessions attached on this connection, with their state.
      # @return [Hash{Uuid => SessionState}]
      def attached_sessions
        @state_mutex.synchronize { @session_states.reject { |id, _| id.nil? } }
      end

      protected

      # Performs one request on the transport.
      # @return [Object] decoded result
      def execute(method, params, session: nil, txn: nil)
        raise NotImplementedError
      end

      # Records the effect of a successful request on its session's state.
      def track_request(method, params, result, session)
        @state_mutex.synchronize do
          case method
          when Protocol::Methods::ATTACH
            @session_states[session] ||= SessionState.new
          when Protocol::Methods::DETACH
            @session_states.delete(session) if session
          else
            @session_states[session]&.track(method, params, result)
          end
        end
      end

      # Renews a session's access token shortly before it expires, so the
      # session does not silently lose its credentials: with the refresh
      # token when there is one, otherwise by signing in again with the
      # credentials it last signed in with. Losing the connection while
      # renewing means the request itself was never sent, so it is reported
      # as NotConnectedError, which is safe to retry, rather than as an error
      # from the request.
      def renew_before(request, session)
        return unless @renew_tokens

        renew_tokens(request, session)
      rescue NotConnectedError
        raise
      rescue ConnectionError => e
        raise NotConnectedError, "connection lost while renewing the access token (#{e.message}); " \
                                 "'#{request}' was not sent"
      end

      # A token that can no longer be renewed is still used until it expires;
      # after that the request is refused, as the server would run it
      # signed out.
      def renew_tokens(request, session)
        state = session_state(session)
        return unless state&.expiring?(@token_refresh_margin) && state.renewable?

        @renew_mutex.synchronize do
          next unless state.expiring?(@token_refresh_margin) # another thread renewed it

          log(:debug, 'Access token expiring; renewing it')
          renew_with(state, session)
        end
      rescue ServerError => e
        log(:warn, "Could not renew the access token: #{e.message}")
        return unless state.expired?

        raise AuthenticationError, "the access token has expired and could not be renewed (#{e.message}); " \
                                   "'#{request}' was not sent"
      end

      def renew_with(state, session)
        if state.refresh_token
          send_request(Protocol::Methods::REFRESH, [state.tokens], session: session)
        else
          send_request(*state.signin, session: session)
        end
      end

      def log(level, message)
        SurrealDB.configuration.logger&.send(level, message)
      end
    end
  end
end
