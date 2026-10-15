# frozen_string_literal: true

module SurrealDB
  module Connections
    # Streaming responses for {WebSocket}: requests such as `query_stream`
    # that the server answers with a sequence of frames under one request id.
    module WebSocketStreams
      protected

      # Frames of a streaming response arrive under the request's id until the
      # server's `end` frame; each is handed to the block as it is read.
      def execute_stream(method, params, session: nil, txn: nil, timeout: nil)
        raise NotConnectedError, 'not connected' unless @connected

        id, encoded = @rpc.encode_request(method, params, session: session, txn: txn)
        frames = Thread::Queue.new
        @mutex.synchronize { @streams[id] = frames }
        done = false
        begin
          write_frame(encoded)
          until done
            begin
              result = next_stream_frame(frames, timeout || @timeout)
            rescue ServerError
              done = true # the server answered with an error: there is no stream to stop
              raise
            end
            done = result.is_a?(Hash) && result['stream'] == 'end'
            yield result
          end
        ensure
          @mutex.synchronize { @streams.delete(id) }
          cancel_stream(id) unless done
        end
      end

      private

      def next_stream_frame(frames, timeout)
        frame = frames.pop(timeout: timeout)
        raise TimeoutError, "no stream frame within #{timeout}s" if frame.nil?
        raise ConnectionError, 'connection closed' if frame == :closed

        Protocol::Response.extract_result(@rpc.decode_response(frame))
      end

      # Asks the server to stop a stream the caller stopped reading. Its last
      # frames arrive after the stream is unregistered and are dropped.
      def cancel_stream(id)
        return unless @connected

        execute(Protocol::Methods::QUERY_CANCEL, [id], timeout: [@timeout, 5].min)
      rescue Error => e
        log(:debug, "query_cancel for stream #{id} failed: #{e.message}")
      end
    end
  end
end
