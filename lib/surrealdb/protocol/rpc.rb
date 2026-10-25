# frozen_string_literal: true

module SurrealDB
  module Protocol
    # Handles RPC request/response framing over CBOR.
    # Thread-safe request ID generation.
    class RPC
      # The CBOR dialects: plain `cbor`, and SurrealDB 4.0's `cbor.2`, which
      # adds the sized numbers.
      FORMATS = %i[cbor cbor2].freeze

      # The dialect the connection negotiated. Requests are encoded in it, and
      # responses decoded in it unless the caller says otherwise.
      # @return [Symbol] :cbor or :cbor2
      attr_reader :format

      def initialize
        @id_counter = 0
        @id_mutex = Mutex.new
        @format = :cbor
      end

      # @param format [Symbol] one of {FORMATS}
      def format=(format)
        raise ArgumentError, "unknown CBOR format #{format.inspect}" unless FORMATS.include?(format)

        @format = format
      end

      # @return [Boolean] whether the connection speaks cbor.2
      def cbor2?
        @format == :cbor2
      end

      # Encodes an RPC request to CBOR bytes.
      #
      # The envelope is `{id, method, params, session?, txn?}`. `session` is
      # only present when the request targets an attached session; without it
      # the server uses the connection's default session. `txn` is only
      # present when the request runs inside an interactive transaction.
      #
      # @param method [String] RPC method name
      # @param params [Array] method parameters
      # @param session [Uuid, nil] attached session to run the request in
      # @param txn [Uuid, nil] transaction to run the request in
      # @return [Array(Integer, String)] request ID and encoded CBOR bytes
      def encode_request(method, params = [], session: nil, txn: nil)
        id = next_id
        cbor2 = cbor2?
        payload = {
          'id' => id,
          'method' => method,
          'params' => CBOR::Encoder.prepare(params, cbor2: cbor2)
        }
        payload['session'] = CBOR::Encoder.prepare(session) if session
        payload['txn'] = CBOR::Encoder.prepare(txn) if txn
        [id, ::CBOR.encode(payload)]
      end

      # Decodes a CBOR response and resolves SurrealDB types.
      #
      # @param data [String] CBOR-encoded binary string
      # @param format [Symbol] the dialect the response is in
      # @return [Hash] decoded response with resolved types
      def decode_response(data, format: @format)
        raw = ::CBOR.decode(data)
        CBOR::Decoder.resolve(raw, cbor2: format == :cbor2)
      end

      private

      def next_id
        @id_mutex.synchronize do
          @id_counter += 1
        end
      end
    end
  end
end
