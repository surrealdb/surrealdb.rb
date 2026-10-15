# frozen_string_literal: true

module SurrealDB
  module Connections
    # Embedded transport for SurrealDB via FFI to libsurrealdb_c.
    #
    # Supports mem://, surrealkv://, and file:// URL schemes. Uses the same
    # CBOR RPC protocol as the WebSocket/HTTP transports, but calls directly
    # into the C library instead of going over the network.
    #
    # Requires `require "surrealdb/embedded"` before use.
    #
    # ## Thread Safety
    #
    # The underlying C library handles its own threading via a Tokio runtime.
    # All FFI calls use `blocking: true` to release the GVL. However, the
    # Ruby-side request lifecycle is not atomic -- use one Client per thread.
    class Embedded < Base
      def initialize(url, **options)
        super
        @timeout = options.fetch(:timeout, SurrealDB.configuration.timeout)
        @strict = options.fetch(:strict, false)
        @rpc_ptr = nil
        @live_handlers = {}
        @mutex = Mutex.new
        @notification_thread = nil
      end

      def connect
        err_ptr = FFI::MemoryPointer.new(:pointer)
        surreal_ptr = FFI::MemoryPointer.new(:pointer)

        opts = Native::SrOption.new
        opts[:strict] = @strict
        opts[:query_timeout] = @timeout
        opts[:transaction_timeout] = @timeout

        ret = Native.sr_surreal_rpc_new(err_ptr, surreal_ptr, @url, opts)
        check_error!(ret, err_ptr)

        @rpc_ptr = surreal_ptr.read_pointer
        @connected = true
        start_notification_stream
        log(:debug, "Embedded connection opened: #{@url}")
      end

      def close
        return unless @connected

        @connected = false
        stop_notification_stream
        Native.sr_surreal_rpc_free(@rpc_ptr) if @rpc_ptr
        @rpc_ptr = nil
        log(:debug, 'Embedded connection closed')
      end

      def send_request(method, params = [])
        raise ConnectionError, 'not connected' unless @connected

        _id, encoded = @rpc.encode_request(method, params)

        err_ptr = FFI::MemoryPointer.new(:pointer)
        res_ptr = FFI::MemoryPointer.new(:pointer)

        ret = Native.sr_surreal_rpc_execute(
          @rpc_ptr, err_ptr, res_ptr,
          encoded, encoded.bytesize
        )
        check_error!(ret, err_ptr)

        read_and_free_response(res_ptr, ret)
      end

      def supports_live_queries?
        true
      end

      # @param live_query_id [String]
      # @param handler [Proc, Queue]
      def on_notification(live_query_id, handler)
        @mutex.synchronize { @live_handlers[live_query_id.to_s] = handler }
      end

      # @param live_query_id [String]
      def remove_notification_handler(live_query_id)
        @mutex.synchronize { @live_handlers.delete(live_query_id.to_s) }
      end

      private

      def read_and_free_response(res_ptr, length)
        raw_ptr = res_ptr.read_pointer
        begin
          bytes = raw_ptr.read_bytes(length)
          response = @rpc.decode_response(bytes)
          Protocol::Response.extract_result(response)
        ensure
          Native.sr_free_byte_arr(raw_ptr, length)
        end
      end

      def check_error!(ret, err_ptr)
        return if ret >= 0

        err_str_ptr = err_ptr.read_pointer
        message = err_str_ptr.null? ? "unknown error (code #{ret})" : err_str_ptr.read_string
        Native.sr_free_string(err_str_ptr) unless err_str_ptr.null?

        if ret == Native::SR_FATAL
          @connected = false
          raise ConnectionError, "fatal error (connection poisoned): #{message}"
        end

        raise ServerError, message
      end

      def start_notification_stream
        err_ptr = FFI::MemoryPointer.new(:pointer)
        stream_ptr = FFI::MemoryPointer.new(:pointer)

        ret = Native.sr_surreal_rpc_notifications(@rpc_ptr, err_ptr, stream_ptr)
        return if ret.negative?

        @stream_ptr = stream_ptr.read_pointer
        @notification_thread = Thread.new do
          Thread.current.report_on_exception = false
          notification_loop
        end
      end

      def notification_loop
        while @connected
          res_ptr = FFI::MemoryPointer.new(:pointer)
          ret = Native.sr_rpc_stream_next(@stream_ptr, res_ptr)

          break if ret == Native::SR_CLOSED || !@connected

          next unless ret.positive?

          raw_ptr = res_ptr.read_pointer
          begin
            bytes = raw_ptr.read_bytes(ret)
            dispatch_notification(bytes)
          ensure
            Native.sr_free_byte_arr(raw_ptr, ret)
          end
        end
      rescue StandardError => e
        log(:warn, "Notification stream error: #{e.class}: #{e.message}")
      ensure
        Native.sr_rpc_stream_free(@stream_ptr) if @stream_ptr
        @stream_ptr = nil
      end

      def dispatch_notification(bytes) # rubocop:disable Metrics/CyclomaticComplexity
        raw = ::CBOR.decode(bytes)
        resolved = CBOR::Decoder.resolve(raw)
        result = resolved.is_a?(Hash) ? (resolved['result'] || resolved) : resolved
        live_id = result['id']&.to_s if result.is_a?(Hash) # a Uuid; handlers are kept by its string
        return unless live_id

        handler = @mutex.synchronize { @live_handlers[live_id] }
        return unless handler

        case handler
        when Queue then handler.push(result)
        when Proc  then handler.call(result)
        end
      end

      def stop_notification_stream
        @notification_thread&.join(2)
        @notification_thread&.kill if @notification_thread&.alive?
        @notification_thread = nil
      end

      def log(level, message)
        SurrealDB.configuration.logger&.send(level, message)
      end
    end
  end
end
