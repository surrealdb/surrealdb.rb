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

        detach_sessions
        @http&.finish if @http&.started?
        @connected = false
        @http = nil
        log(:debug, 'HTTP connection closed')
      end

      # The server refuses `sessions` over HTTP.
      # @return [Boolean]
      def supports_session_listing?
        false
      end

      protected

      def execute(method, params, session: nil)
        raise ConnectionError, 'not connected' unless @connected

        _id, encoded = @rpc.encode_request(method, params, session: session)

        request = build_request(encoded, session_state(session) || session_state)
        response = execute_request(request)

        decoded = @rpc.decode_response(response.body)
        Protocol::Response.extract_result(decoded)
      end

      private

      # The server keeps an attached HTTP session until it is detached:
      # unlike a WebSocket's, it does not end with the connection.
      def detach_sessions
        attached_sessions.each_key do |id|
          send_request(Protocol::Methods::DETACH, [], session: id)
        rescue ServerError => e
          log(:debug, "Could not detach session #{id} on close: #{e.message}")
        rescue Error => e
          log(:debug, "Could not detach sessions on close: #{e.message}")
          break # the server cannot be reached; the others would only wait as long
        end
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
