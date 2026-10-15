# frozen_string_literal: true

require 'net/http'
require 'uri'

module SurrealDB
  module Connections
    # HTTP transport for SurrealDB RPC.
    #
    # Each request is a synchronous POST to /rpc with a CBOR body.
    # Does not support live queries, listing sessions, or transactions.
    #
    # ## Thread Safety
    #
    # A single HTTP connection is NOT safe for concurrent use from multiple
    # threads. The underlying Net::HTTP instance is not thread-safe and the
    # header state (ns/db/token) is shared. Use a separate Client per thread
    # or wrap calls in your own Mutex.
    class HTTP < Base
      # Errors that mean the kept-alive socket was already dead: the server
      # closed it while idle, and the close raced our request.
      STALE_CONNECTION_ERRORS = [EOFError, Errno::EPIPE, Errno::ECONNRESET, Errno::ECONNABORTED].freeze

      def initialize(url, **options)
        super
        @timeout = options.fetch(:timeout, SurrealDB.configuration.timeout)
        @http = nil
        @requests_on_socket = 0
      end

      def connect
        uri = URI.parse(@url)
        @http = Net::HTTP.new(uri.host, uri.port)
        @http.use_ssl = (uri.scheme == 'https')
        @http.open_timeout = @timeout
        @http.read_timeout = @timeout

        @http.verify_mode = OpenSSL::SSL::VERIFY_PEER if @http.use_ssl?

        start_http
        @connected = true
        log(:debug, "HTTP connected to #{@url}")
      end

      def close
        return unless @connected

        @http&.finish if @http&.started?
        @connected = false
        @http = nil
        log(:debug, 'HTTP connection closed')
      end

      # The server has no begin/commit/cancel over HTTP.
      def supports_transactions?
        false
      end

      # The server refuses `sessions` over HTTP.
      # @return [Boolean]
      def supports_session_listing?
        false
      end

      protected

      # Methods that take query variables as their second param.
      VARIABLE_METHODS = [Protocol::Methods::QUERY].freeze

      def execute(method, params, session: nil, txn: nil)
        raise ConnectionError, 'not connected' unless @connected

        # Without an attached session every HTTP request runs in a fresh server
        # session, so a variable set with `let` would be gone by the next
        # request. Keep variables on the client (Base#track_request records
        # them) and send them with each query instead. `let` and `unset` are
        # still sent, so the server refuses what it would refuse over
        # WebSocket (a protected name such as `auth`) before it is recorded.
        params = with_variables(method, params) if session.nil?

        _id, encoded = @rpc.encode_request(method, params, session: session, txn: txn)

        request = build_request(encoded, session_state(session) || session_state)
        response = execute_request(request, repeatable: txn.nil? && Protocol::Methods::SAFE_TO_REPEAT.include?(method))

        decoded = @rpc.decode_response(response.body)
        Protocol::Response.extract_result(decoded)
      end

      private

      def with_variables(method, params)
        return params unless VARIABLE_METHODS.include?(method)

        variables = session_state.variables
        return params if variables.empty?

        [params[0], variables.merge(params[1] || {})]
      end

      # Each HTTP request runs in a fresh server session unless it names an
      # attached one, so the namespace, database and token the client has
      # been given travel as headers on every request.
      def build_request(body, state)
        uri = URI.parse(@url)
        path = uri.path.empty? ? '/rpc' : uri.path

        req = Net::HTTP::Post.new(path)
        req['Content-Type'] = 'application/cbor'
        req['Accept'] = 'application/cbor'
        req['Authorization'] = "Bearer #{state.access_token}" if state.access_token
        req['surreal-ns'] = state.namespace if state.namespace
        req['surreal-db'] = state.database if state.database
        req.body = body
        req
      end

      # Sends the request on the kept-alive connection.
      #
      # If that socket turns out to be dead (the server closed it while idle,
      # racing our request), a request that is safe to repeat is sent once
      # more on a new socket. Anything else raises RequestInterruptedError:
      # a reset before the response does not prove the server never ran it.
      # (Net::HTTP already reopens sockets that sat idle past
      # keep_alive_timeout or that the server has visibly closed, so this race
      # is narrow.)
      def execute_request(request, repeatable:)
        response = transport(request, repeatable: repeatable)
        HTTPEndpoint.raise_for(response, 'request') unless response.is_a?(Net::HTTPSuccess)

        response
      end

      def transport(request, repeatable:, retried: false)
        open_socket
        reused = @requests_on_socket.positive?
        response = @http.request(request)
        @requests_on_socket += 1
        response
      rescue *STALE_CONNECTION_ERRORS => e
        drop_socket
        # The request was written, on a fresh socket as much as on a reused one.
        unless repeatable
          raise RequestInterruptedError,
                "HTTP connection failed while the request was in flight (#{e.class}); " \
                'it was not sent again because it may already have run'
        end
        raise ConnectionError, "HTTP connection error: #{e.class}: #{e.message}" if !reused || retried

        log(:debug, "HTTP keep-alive socket was stale (#{e.class}); retrying on a new one")
        transport(request, repeatable: true, retried: true)
      rescue Net::OpenTimeout, Net::ReadTimeout => e
        drop_socket
        raise TimeoutError, "HTTP request timed out: #{e.message}"
      rescue Errno::ECONNREFUSED, SocketError, IOError, OpenSSL::SSL::SSLError => e
        drop_socket
        raise ConnectionError, "HTTP connection error: #{e.class}: #{e.message}"
      end

      # Opening a socket sends nothing, so a failure here means the request
      # was never sent.
      def open_socket
        return if @http.started?

        start_http
      rescue Net::OpenTimeout => e
        raise TimeoutError, "HTTP connect timed out: #{e.message}"
      rescue SystemCallError, SocketError, IOError, OpenSSL::SSL::SSLError => e
        raise NotConnectedError, "cannot open an HTTP connection: #{e.class}: #{e.message}"
      end

      def start_http
        @http.start
        @requests_on_socket = 0
      end

      # Drops the current socket. The next request opens a new one (see
      # #transport), so one failed request does not leave the client
      # unusable, and a failed request does not also wait for a reconnect.
      def drop_socket
        @http.finish if @http.started?
      rescue IOError
        nil
      end

      def log(level, message)
        SurrealDB.configuration.logger&.send(level, message)
      end
    end
  end
end
