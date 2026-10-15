# frozen_string_literal: true

module SurrealDB
  module Connections
    # Abstract base class for SurrealDB transport connections.
    # Subclasses must implement #connect, #close, and #execute.
    class Base
      # @return [String] base URL
      attr_reader :url

      # @return [Protocol::RPC]
      attr_reader :rpc

      def initialize(url, **_options)
        @url = url
        @rpc = Protocol::RPC.new
        @connected = false
        @state_mutex = Mutex.new
        @session_states = { nil => SessionState.new }
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

      def log(level, message)
        SurrealDB.configuration.logger&.send(level, message)
      end
    end
  end
end
