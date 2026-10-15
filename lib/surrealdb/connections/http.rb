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
      def initialize(url, **options)
        super
        @timeout = options.fetch(:timeout, SurrealDB.configuration.timeout)
        @http = nil
      end

      def connect
        uri = URI.parse(@url)
        @http = Net::HTTP.new(uri.host, uri.port)
        @http.use_ssl = (uri.scheme == 'https')
        @http.open_timeout = @timeout
        @http.read_timeout = @timeout

        @http.verify_mode = OpenSSL::SSL::VERIFY_PEER if @http.use_ssl?

        @http.start
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

      def execute_request(request)
        response = @http.request(request)

        raise ConnectionError, "HTTP #{response.code}: #{response.message}" unless response.is_a?(Net::HTTPSuccess)

        response
      rescue Net::OpenTimeout, Net::ReadTimeout => e
        raise TimeoutError, "HTTP request timed out: #{e.message}"
      rescue Errno::ECONNREFUSED, Errno::ECONNRESET, SocketError => e
        @connected = false
        raise ConnectionError, "HTTP connection error: #{e.message}"
      end

      def log(level, message)
        SurrealDB.configuration.logger&.send(level, message)
      end
    end
  end
end
