# frozen_string_literal: true

module SurrealDB
  # Wraps a single statement result from a multi-statement query.
  # Each statement in a SurrealQL query produces a separate QueryResult
  # with its own status, timing, result data, and optional error.
  class QueryResult
    # @return [String] "OK" or "ERR"
    attr_reader :status

    # @return [String, nil] execution time (e.g. "1.234ms")
    attr_reader :time

    # @return [Object] the statement's result data
    attr_reader :result

    # @return [String, nil] error message if status is "ERR"
    attr_reader :error

    # @return [String, nil] structured error kind if status is "ERR"
    attr_reader :kind

    # @return [Hash, nil] structured error details if status is "ERR"
    attr_reader :details

    def initialize(status:, time: nil, result: nil, error: nil, kind: nil, details: nil, cause: nil) # rubocop:disable Metrics/ParameterLists
      @status = status
      @time = time
      @result = result
      @error = error
      @kind = kind
      @details = details
      @cause = cause
    end

    # The statement's failure as an exception, of the {ServerError} subclass
    # matching its kind.
    # @return [ServerError, nil] nil when the statement succeeded
    def to_error
      return nil unless error?

      ServerError.from_response(
        { 'message' => @error, 'kind' => @kind, 'details' => @details, 'cause' => @cause }.compact
      )
    end

    # @return [Boolean] true when the statement executed without error
    def ok?
      status == 'OK'
    end

    # @return [Boolean] true when the statement produced an error
    def error?
      status == 'ERR'
    end

    # Builds a QueryResult from a server response hash.
    # @param data [Hash] e.g. {"status"=>"OK", "time"=>"1ms", "result"=>[...]}
    # @return [QueryResult]
    def self.from_response(data)
      return new(status: 'OK', result: data) unless data.is_a?(Hash) && data.key?('status')

      # A failed statement carries its message in `result` (and, on 3.x,
      # its structured kind, details and cause alongside).
      if data['status'] == 'ERR'
        return new(status: 'ERR', time: data['time'], error: (data['error'] || data['result']).to_s,
                   kind: data['kind'], details: data['details'], cause: data['cause'])
      end

      new(status: data['status'], time: data['time'], result: data['result'])
    end

    def inspect
      "#<SurrealDB::QueryResult status=#{@status.inspect} time=#{@time.inspect}>"
    end
  end
end
