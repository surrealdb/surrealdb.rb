# frozen_string_literal: true

require 'net/http'
require 'uri'

module SurrealDB
  module Connections
    # HTTP transport for SurrealDB RPC.
    #
    # Each request is a synchronous POST to /rpc with a CBOR body.
    # Does not support live queries, sessions, or transactions.
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

      protected

      # Methods that take query variables as their second param.
      VARIABLE_METHODS = [Protocol::Methods::QUERY].freeze

      def execute(method, params, session: nil, txn: nil)
        raise ConnectionError, 'not connected' unless @connected

        # Without an attached session every HTTP request runs in a fresh server
        # session, so a variable set with `let` would be gone by the next
        # request. Keep variables on the client (Base#track_request records
        # them) and send them with each query instead.
        if session.nil?
          return nil if [Protocol::Methods::LET, 'set', Protocol::Methods::UNSET].include?(method)

          params = with_variables(method, params)
        end

        _id, encoded = @rpc.encode_request(method, params, session: session, txn: txn)

        request = build_request(encoded, session_state(session) || session_state)
        response = execute_request(request)

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
      # racing our request), the request is sent once more on a new socket.
      # This is safe for every method, not just idempotent ones: it only
      # happens on a socket that already served a request, and the error
      # arrives before any response byte, which is the case where the server
      # dropped the request unread. Go's net/http retries the same case.
      def execute_request(request)
        response = transport(request)
        HTTPEndpoint.raise_for(response, 'request') unless response.is_a?(Net::HTTPSuccess)

        response
      end

      def transport(request, retried: false)
        start_http unless @http.started?
        reused = @requests_on_socket.positive?
        response = @http.request(request)
        @requests_on_socket += 1
        response
      rescue *STALE_CONNECTION_ERRORS => e
        restart_http
        if reused && !retried
          log(:debug, "HTTP keep-alive socket was stale (#{e.class}); retrying on a new one")
          return transport(request, retried: true)
        end
        raise ConnectionError, "HTTP connection error: #{e.class}: #{e.message}"
      rescue Net::OpenTimeout, Net::ReadTimeout => e
        restart_http
        raise TimeoutError, "HTTP request timed out: #{e.message}"
      rescue Errno::ECONNREFUSED, SocketError, IOError, OpenSSL::SSL::SSLError => e
        restart_http
        raise ConnectionError, "HTTP connection error: #{e.class}: #{e.message}"
      end

      def start_http
        @http.start
        @requests_on_socket = 0
      end

      # Drops the current socket. The next request opens a new one, so one
      # failed request does not leave the client unusable.
      def restart_http
        @http.finish if @http.started?
      rescue IOError
        nil
      ensure
        begin
          start_http
        rescue StandardError => e
          log(:debug, "HTTP reconnect deferred: #{e.class}: #{e.message}")
        end
      end

      def log(level, message)
        SurrealDB.configuration.logger&.send(level, message)
      end
    end
  end
end
