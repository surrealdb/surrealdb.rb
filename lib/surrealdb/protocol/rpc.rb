# frozen_string_literal: true

module SurrealDB
  module Protocol
    # Handles RPC request/response framing over CBOR.
    # Thread-safe request ID generation.
    class RPC
      def initialize
        @id_counter = 0
        @id_mutex = Mutex.new
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
        payload = {
          'id' => id,
          'method' => method,
          'params' => CBOR::Encoder.prepare(params)
        }
        payload['session'] = CBOR::Encoder.prepare(session) if session
        payload['txn'] = CBOR::Encoder.prepare(txn) if txn
        [id, ::CBOR.encode(payload)]
      end

      # Decodes a CBOR response and resolves SurrealDB types.
      #
      # @param data [String] CBOR-encoded binary string
      # @return [Hash] decoded response with resolved types
      def decode_response(data)
        raw = ::CBOR.decode(data)
        CBOR::Decoder.resolve(raw)
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
