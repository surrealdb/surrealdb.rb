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
      # An HTTPS peer that closes the socket without a TLS close_notify makes
      # OpenSSL raise this instead of EOFError.
      module TLSEndOfFile
        def self.===(error)
          error.is_a?(OpenSSL::SSL::SSLError) && error.message.match?(/unexpected eof/i)
        end
      end

      CBOR_MIME = 'application/cbor'
      CBOR2_MIME = 'application/cbor; v=2'
      CBOR2_MEDIA_TYPE = %r{\A\s*application/cbor\s*;(?:[^;]*;)*\s*v\s*=\s*"?2"?\s*(?:;|\z)}i

      STALE_CONNECTION_ERRORS = [EOFError, Errno::EPIPE, Errno::ECONNRESET, Errno::ECONNABORTED, TLSEndOfFile].freeze

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
        @http.write_timeout = @timeout

        @http.verify_mode = OpenSSL::SSL::VERIFY_PEER if @http.use_ssl?

        start_http
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
      VARIABLE_METHODS = [Protocol::Methods::QUERY, Protocol::Methods::GQL].freeze

      # Methods that carry their own credentials in the body. They are sent
      # without the bearer header: when the current access token has expired,
      # the server would refuse the whole request because of it.
      CREDENTIAL_METHODS = [
        Protocol::Methods::SIGNIN, Protocol::Methods::SIGNUP, Protocol::Methods::AUTHENTICATE,
        Protocol::Methods::REFRESH, Protocol::Methods::REVOKE
      ].freeze

      def execute(method, params, session: nil, txn: nil, timeout: nil)
        raise ConnectionError, 'not connected' unless @connected

        # Without an attached session every HTTP request runs in a fresh server
        # session, so a variable set with `let` would be gone by the next
        # request. Keep variables on the client (Base#track_request records
        # them) and send them with each query instead. `let` and `unset` are
        # still sent, so the server refuses what it would refuse over
        # WebSocket (a protected name such as `auth`) before it is recorded.
        params = with_variables(method, params) if session.nil?

        format = @rpc.format
        _id, encoded = @rpc.encode_request(method, params, session: session, txn: txn)

        request = build_request(encoded, format, session_state(session) || session_state,
                                bearer: !CREDENTIAL_METHODS.include?(method))
        response = with_call_timeout(timeout) do
          execute_request(request, repeatable: txn.nil? && Protocol::Methods::SAFE_TO_REPEAT.include?(method))
        end

        decode(response)
      end

      private

      def with_variables(method, params)
        return params unless VARIABLE_METHODS.include?(method)

        variables = session_state.variables
        return params if variables.empty?

        [params[0], variables.merge(params[1] || {})]
      end

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
      #
      # Every request asks for `cbor.2`. A SurrealDB 4.0 server answers in it,
      # and only then does the body go out as `cbor.2`: 4.0 refuses a `cbor.2`
      # body that asks for a plain `cbor` answer, and an older server answers
      # plain `cbor` whatever it is asked.
      def build_request(body, format, state, bearer: true)
        uri = URI.parse(@url)
        path = uri.path.empty? ? '/rpc' : uri.path

        req = Net::HTTP::Post.new(path)
        req['Content-Type'] = format == :cbor2 ? CBOR2_MIME : CBOR_MIME
        req['Accept'] = CBOR2_MIME
        req['Authorization'] = "Bearer #{state.access_token}" if bearer && state.access_token
        req['surreal-ns'] = state.namespace if state.namespace
        req['surreal-db'] = state.database if state.database
        req.body = body
        req
      end

      # Decodes the response in the dialect its Content-Type names, which the
      # next request is then encoded in.
      def decode(response)
        @rpc.format = cbor2_media_type?(response['Content-Type']) ? :cbor2 : :cbor
        Protocol::Response.extract_result(@rpc.decode_response(response.body))
      end

      # `application/cbor; v=2`, with any spacing, case or quoting.
      def cbor2_media_type?(content_type)
        CBOR2_MEDIA_TYPE.match?(content_type.to_s)
      end

      # A call's timeout is one deadline for opening a new socket and reading
      # the response: reading gets the time opening left (see #open_socket).
      def with_call_timeout(timeout)
        return yield if timeout.nil?

        @call_deadline = monotonic_now + timeout
        @http.open_timeout = timeout
        @http.read_timeout = timeout
        @http.write_timeout = timeout
        begin
          yield
        ensure
          @call_deadline = nil
          @http.open_timeout = @timeout
          @http.read_timeout = @timeout
          @http.write_timeout = @timeout
        end
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
        unless response.is_a?(Net::HTTPSuccess)
          # A server that refuses a request without reading its body (a 401,
          # say) may close the connection without saying so, which would fail
          # the next request on it as if it were in flight.
          drop_socket
          HTTPEndpoint.raise_for(response, 'request')
        end

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
      rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout => e
        drop_socket
        # The server runs a request only once it has the whole body.
        raise TimeoutError.new("HTTP request timed out: #{e.message}", sent: e.is_a?(Net::ReadTimeout))
      rescue Errno::ECONNREFUSED, SocketError, IOError, OpenSSL::SSL::SSLError => e
        drop_socket
        raise ConnectionError, "HTTP connection error: #{e.class}: #{e.message}"
      rescue Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError => e
        drop_socket
        raise ProtocolError, "HTTP got a malformed response: #{e.message}"
      end

      # Opening a socket sends nothing, so a failure here means the request
      # was never sent.
      def open_socket
        return if @http.started?

        within_deadline(:open_timeout)
        start_http
        within_deadline(:read_timeout, :write_timeout)
      rescue Net::OpenTimeout => e
        raise TimeoutError.new("HTTP connect timed out: #{e.message}", sent: false)
      rescue SystemCallError, SocketError, IOError, OpenSSL::SSL::SSLError => e
        raise NotConnectedError, "cannot open an HTTP connection: #{e.class}: #{e.message}"
      end

      # Gives each phase of a call (opening a socket, again after a stale
      # one; writing; reading) only the time its deadline has left.
      def within_deadline(*timeouts)
        return unless @call_deadline

        left = @call_deadline - monotonic_now
        raise TimeoutError.new('HTTP request timed out while connecting', sent: false) unless left.positive?

        timeouts.each { |timeout| @http.public_send(:"#{timeout}=", left) }
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
