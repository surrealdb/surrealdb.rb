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
      # @return [URI::HTTP] base URL, without the trailing /rpc
      attr_reader :base

      # @param url [String] the connection URL (ws://, wss://, http://, https://)
      # @param timeout [Numeric] read and open timeout in seconds
      def initialize(url, timeout:)
        uri = URI.parse(url)
        scheme = { 'ws' => 'http', 'wss' => 'https' }.fetch(uri.scheme, uri.scheme)
        path = uri.path.to_s.sub(%r{/rpc/?\z}, '').chomp('/')
        default_port = scheme == 'https' ? 443 : 80
        port = uri.port == default_port ? nil : uri.port
        @base = URI::Generic.build(scheme: scheme, host: uri.host, port: port, path: path)
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
      rescue Net::OpenTimeout, Net::ReadTimeout => e
        raise TimeoutError, "HTTP #{path} timed out: #{e.message}"
      rescue SystemCallError, IOError, SocketError, OpenSSL::SSL::SSLError => e
        raise ConnectionError, "HTTP #{path} failed: #{e.class}: #{e.message}"
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
          req.body_stream = body
          req['Transfer-Encoding'] = 'chunked' unless req['Content-Length']
        elsif body
          req.body = body
        end
      end
    end
  end
end
