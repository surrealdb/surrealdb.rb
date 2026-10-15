# frozen_string_literal: true

module SurrealDB
  module Connections
    # The frames of one streaming response, on their way from the reader
    # thread to the caller. The buffer is bounded so a large result is never
    # held whole: when the caller falls behind, the reader thread waits for
    # it, which stops reading the socket and so slows the server down.
    class StreamFrames
      # Frames buffered before the reader thread waits for the caller.
      CAPACITY = 32

      def initialize(capacity = CAPACITY)
        @queue = Thread::SizedQueue.new(capacity)
        @error = nil
      end

      # @return [Boolean] false if the caller made no room within timeout
      def push(frame, timeout)
        !@queue.push(frame, timeout: timeout).nil?
      rescue ClosedQueueError
        false
      end

      # Ends the stream: the caller gets the frames already buffered, then
      # this error. Never blocks.
      def fail(error)
        @error ||= error
        @queue.close
      end

      # The caller stopped reading: frames still on their way are dropped.
      # Never blocks.
      def close
        @queue.close
      end

      # @raise [Error] the error the stream failed with, or TimeoutError
      def pop(timeout)
        frame = @queue.pop(timeout: timeout)
        return frame unless frame.nil?
        raise @error if @error

        raise TimeoutError, "no stream frame within #{timeout}s"
      end
    end

    # Streaming responses for {WebSocket}: requests such as `query_stream`
    # that the server answers with a sequence of frames under one request id.
    module WebSocketStreams
      protected

      # Frames of a streaming response arrive under the request's id until the
      # server's `end` frame; each is handed to the block as it is read.
      def execute_stream(method, params, session: nil, txn: nil, timeout: nil)
        raise NotConnectedError, 'not connected' unless @connected

        id, encoded = @rpc.encode_request(method, params, session: session, txn: txn)
        frames = StreamFrames.new
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
          # Frees the reader thread if it is waiting for room for another
          # frame, so it can read the cancellation's response.
          frames.close
          cancel_stream(id) unless done
        end
      end

      private

      def next_stream_frame(frames, timeout)
        Protocol::Response.extract_result(@rpc.decode_response(frames.pop(timeout)))
      end

      # Called by the reader thread with a frame for a stream. It waits up to
      # the connection's timeout for the caller to make room, and gives the
      # stream up after that, so a caller that stopped reading cannot hold
      # up every other response on the connection for longer.
      def feed_stream(id, frames, bytes)
        return if frames.push(bytes, @timeout)

        @mutex.synchronize { @streams.delete(id) if @streams[id].equal?(frames) }
        frames.fail(TimeoutError.new("stream not read for #{@timeout}s; it was stopped"))
      end

      # Asks the server to stop a stream the caller stopped reading. Its last
      # frames arrive after the stream is unregistered and are dropped.
      #
      # A server that refuses `query_cancel` (it is a capability of its own)
      # cannot stop a stream, which then runs to the end with its frames
      # dropped. Later queries on this connection run buffered instead, so
      # there is never a stream to leave running.
      def cancel_stream(id)
        return unless @connected

        execute(Protocol::Methods::QUERY_CANCEL, [id], timeout: [@timeout, 5].min)
      rescue ServerError => e
        streaming_unavailable!
        log(:warn, "The server refused to stop stream #{id} (#{e.message}); it runs on, and later queries " \
                   'on this connection will not stream')
      rescue Error => e
        log(:debug, "query_cancel for stream #{id} failed: #{e.message}")
      end
    end
  end
end
