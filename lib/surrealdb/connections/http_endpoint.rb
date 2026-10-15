# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'

module SurrealDB
  module Connections
    # Requests to the server's plain HTTP routes (/import, /export, /health),
    # which have no RPC method. Works for any remote connection: a ws:// URL
    # is turned into the matching http:// one.
    class HTTPEndpoint
      # @return [URI::HTTP, URI::HTTPS] base URL, without the trailing /rpc
      attr_reader :base

      # @param url [String] the connection URL (ws://, wss://, http://, https://)
      # @param timeout [Numeric] read and open timeout in seconds
      def initialize(url, timeout:)
        uri = URI.parse(url)
        scheme = { 'ws' => 'http', 'wss' => 'https' }.fetch(uri.scheme, uri.scheme)
        path = uri.path.to_s.sub(%r{/rpc/?\z}, '').chomp('/')
        # URI::HTTP(S) fill in the scheme's default port when the URL has none
        # and leave it out of #to_s.
        klass = scheme == 'https' ? URI::HTTPS : URI::HTTP
        @base = klass.build(host: uri.host, port: uri.port, path: path)
        @timeout = timeout
      end

      # Sends a request and returns the response. With a block, the body is
      # streamed to the block in chunks and not kept on the response.
      #
      # @param verb [Symbol] :get or :post
      # @param path [String] e.g. "/import"
      # @param body [String, IO, nil]
      # @param headers [Hash{String => String}]
      # @param state [SessionState, nil] supplies the namespace, database and token
      # @yield [String] body chunks, when given
      # @return [Net::HTTPResponse]
      def request(verb, path, body: nil, headers: {}, state: nil, &block)
        req = build(verb, path, body, headers, state)
        block &&= guard(block)
        http = Net::HTTP.new(@base.host, @base.port)
        http.use_ssl = @base.scheme == 'https'
        http.open_timeout = @timeout
        http.read_timeout = @timeout
        http.start do |conn|
          conn.request(req) do |response|
            if block && response.is_a?(Net::HTTPSuccess)
              response.read_body(&block)
            else
              response.read_body
            end
            return response
          end
        end
      rescue BlockError => e
        raise e.original
      rescue Net::OpenTimeout, Net::ReadTimeout => e
        raise TimeoutError, "HTTP #{path} timed out: #{e.message}"
      rescue SystemCallError, IOError, SocketError, OpenSSL::SSL::SSLError => e
        raise ConnectionError, "HTTP #{path} failed: #{e.class}: #{e.message}"
      end

      # An error the caller's block raised while reading a streamed body, or
      # the caller's IO raised while it was read for the request body. It is
      # carried past the transport rescues and re-raised unchanged, so a
      # local failure (a full disk, an unreadable file) is not reported as a
      # network one, which a caller might retry.
      class BlockError < StandardError
        # @return [Exception]
        attr_reader :original

        def initialize(original)
          @original = original
          super(original.message)
        end
      end

      # The caller's IO, as the request body: its own errors are wrapped in
      # a {BlockError} so they reach the caller as they were raised.
      class GuardedBody
        def initialize(source)
          @io = source
        end

        def read(*)
          @io.read(*)
        rescue StandardError => e
          raise BlockError, e
        end
      end

      # Raises the error a failed response stands for.
      # @param response [Net::HTTPResponse]
      # @param what [String] what was being done, for the message
      # @raise [ServerError]
      def self.raise_for(response, what)
        message = error_message(response)
        klass = case response.code.to_i
                when 401, 403 then NotAllowedError
                when 404 then NotFoundError
                else ServerError
                end
        raise klass.new("#{what} failed (HTTP #{response.code}): #{message}", code: response.code.to_i)
      end

      def self.error_message(response)
        body = response.body.to_s
        parsed = JSON.parse(body)
        return body unless parsed.is_a?(Hash)

        parsed['information'] || parsed['details'] || parsed['description'] || body
      rescue JSON::ParserError
        body.empty? ? response.message : body
      end
      private_class_method :error_message

      private

      def build(verb, path, body, headers, state)
        full = "#{@base.path}#{path}"
        req = verb == :get ? Net::HTTP::Get.new(full) : Net::HTTP::Post.new(full)
        headers.each { |k, v| req[k] = v }
        apply_state(req, state) if state
        attach_body(req, body)
        req
      end

      def apply_state(req, state)
        req['Authorization'] = "Bearer #{state.access_token}" if state.access_token
        req['surreal-ns'] = state.namespace if state.namespace
        req['surreal-db'] = state.database if state.database
      end

      def attach_body(req, body)
        if body.respond_to?(:read)
          req.body_stream = GuardedBody.new(body)
          req['Transfer-Encoding'] = 'chunked' unless req['Content-Length']
        elsif body
          req.body = body
        end
      end

      def guard(block)
        lambda do |chunk|
          block.call(chunk)
        rescue StandardError => e
          raise BlockError, e
        end
      end
    end
  end
end
