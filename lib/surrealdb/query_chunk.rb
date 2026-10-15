# frozen_string_literal: true

module SurrealDB
  # Part of a statement's result, as {QueryMethods#query_stream} yields it.
  #
  # A statement that returns rows (a SELECT, say) arrives as zero or more
  # `:rows` chunks; one that returns a single value (a RETURN) as one
  # `:value` chunk. Every statement ends with a `:finished` chunk carrying
  # its time and, when it failed, its error. Rows are only final once their
  # statement's `:finished` chunk has no error: a statement that fails
  # midway retracts the rows already sent.
  class QueryChunk
    # @return [Integer] the statement's position in the query, from 0
    attr_reader :index

    # @return [Symbol] :rows, :value or :finished
    attr_reader :kind

    # @return [Array] the rows in a :rows chunk, the value (as a one-element
    #   array) in a :value chunk, nothing in a :finished chunk
    attr_reader :values

    # @return [String, nil] how long the statement took (:finished only)
    attr_reader :time

    # @return [ServerError, nil] why the statement failed (:finished only)
    attr_reader :error

    # @return [Boolean, nil] whether the statement's result is one value
    #   rather than a list of rows (:finished chunks from a stream only)
    attr_reader :single

    def initialize(index:, kind:, values: [], time: nil, error: nil, single: nil) # rubocop:disable Metrics/ParameterLists
      @index = index
      @kind = kind
      @values = values
      @time = time
      @error = error
      @single = single
    end

    # Builds a chunk from a `query_stream` frame.
    # @param frame [Hash] the frame's result
    # @return [QueryChunk, nil] nil for the frames around the statements
    #   (`begin` and `end`)
    def self.from_frame(frame)
      index = frame['index']
      case frame['stream']
      when 'rows' then new(index: index, kind: :rows, values: Array(frame['values']))
      when 'value' then new(index: index, kind: :value, values: [frame['value']])
      when 'finished'
        new(index: index, kind: :finished, time: frame['time'], error: frame_error(frame['error']),
            single: frame['single'])
      end
    end

    # The result chunk a stream leaves out for a statement that sent no rows
    # or value frame: an empty list, or NONE when `single` says the result is
    # one value. Buffered results always have one, so streamed ones get it
    # too.
    # @param finished [QueryChunk] the statement's :finished chunk
    # @return [QueryChunk]
    def self.implied_by(finished)
      if finished.single
        new(index: finished.index, kind: :value, values: [NONE])
      else
        new(index: finished.index, kind: :rows, values: [])
      end
    end

    # The chunks the buffered result of a query stands for, for servers and
    # connections that cannot stream.
    # @param results [Array<QueryResult>]
    # @return [Array<QueryChunk>]
    def self.from_results(results)
      results.each_with_index.flat_map do |result, index|
        finished = new(index: index, kind: :finished, time: result.time, error: result.to_error)
        next [finished] if result.error?

        data = if result.result.is_a?(Array)
                 new(index: index, kind: :rows, values: result.result)
               else
                 new(index: index, kind: :value, values: [result.result])
               end
        [data, finished]
      end
    end

    def self.frame_error(error)
      return nil if error.nil? || error.is_a?(None)

      error.is_a?(Hash) ? ServerError.from_response(error) : ServerError.new(error.to_s)
    end
    private_class_method :frame_error

    # @return [Object] the value of a :value chunk
    def value
      @values.first
    end

    # @return [Boolean] whether this is a :rows chunk
    def rows?
      @kind == :rows
    end

    # @return [Boolean] whether this is the statement's :finished chunk
    def finished?
      @kind == :finished
    end

    # @return [Boolean] whether the statement failed (:finished only)
    def error?
      !@error.nil?
    end

    def inspect
      error = " error=#{@error.message.inspect}" if @error
      "#<SurrealDB::QueryChunk index=#{@index} kind=#{@kind} values=#{@values.size}#{error}>"
    end
  end
end
