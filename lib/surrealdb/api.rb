# frozen_string_literal: true

module SurrealDB
  # The response of a user-defined API endpoint.
  class ApiResponse
    # @return [Integer] HTTP status the endpoint answered with
    attr_reader :status

    # @return [Hash{String => String}]
    attr_reader :headers

    # @return [Object] the response body
    attr_reader :body

    def initialize(status:, headers: {}, body: nil, method: nil, path: nil)
      @status = status
      @headers = headers
      @body = body
      @method = method
      @path = path
    end

    # @return [Boolean] whether the status is 2xx
    def success?
      @status.is_a?(Integer) && @status.between?(200, 299)
    end

    # The body of a successful response.
    # @return [Object]
    # @raise [ApiError] when the status is not 2xx
    def value
      raise ApiError.new(@method, @path, self) unless success?

      @body
    end

    def inspect
      "#<SurrealDB::ApiResponse status=#{@status} body=#{@body.inspect}>"
    end
  end

  # Invokes the server's user-defined APIs (`DEFINE API`) through
  # `api::invoke`, in the session (and transaction) it was created from.
  # Create one with {QueryMethods#api}.
  class Api
    # @return [String] prepended to every path
    attr_reader :prefix

    # @param target [Client, Session, Transaction] runs the requests
    # @param prefix [String]
    def initialize(target, prefix = '')
      @target = target
      @prefix = prefix.to_s
      @headers = {}
    end

    # Sets a header sent with every request from this object.
    # @param name [String]
    # @param value [String, nil] nil removes the header
    # @return [self]
    def header(name, value)
      value.nil? ? @headers.delete(name.to_s) : @headers[name.to_s] = value.to_s
      self
    end

    # Invokes an endpoint.
    # @param path [String] appended to the prefix
    # @param method [String, Symbol] HTTP method
    # @param body [Object, nil]
    # @param headers [Hash{String => String}] sent on top of {#header}s
    # @param query [Hash{String => String}] query string parameters
    # @return [ApiResponse]
    def invoke(path, method: :get, body: nil, headers: {}, query: {})
      full = "#{@prefix}#{path}"
      request = {
        'method' => method.to_s.downcase,
        'headers' => @headers.merge(headers.transform_keys(&:to_s)),
        'query' => query.transform_keys(&:to_s)
      }
      request['body'] = body unless body.nil?
      result = @target.query('RETURN api::invoke($api_path, $api_request)',
                             { 'api_path' => full, 'api_request' => request })[0]
      ApiResponse.new(status: result['status'], headers: result['headers'] || {}, body: result['body'],
                      method: method, path: full)
    end

    # @return [ApiResponse]
    def get(path = '', query: {}, headers: {})
      invoke(path, method: :get, query: query, headers: headers)
    end

    # @return [ApiResponse]
    def post(path = '', body = nil, query: {}, headers: {})
      invoke(path, method: :post, body: body, query: query, headers: headers)
    end

    # @return [ApiResponse]
    def put(path = '', body = nil, query: {}, headers: {})
      invoke(path, method: :put, body: body, query: query, headers: headers)
    end

    # @return [ApiResponse]
    def patch(path = '', body = nil, query: {}, headers: {})
      invoke(path, method: :patch, body: body, query: query, headers: headers)
    end

    # @return [ApiResponse]
    def delete(path = '', body = nil, query: {}, headers: {})
      invoke(path, method: :delete, body: body, query: query, headers: headers)
    end
  end
end
