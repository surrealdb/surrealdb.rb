# frozen_string_literal: true

require 'socket'
require 'io/wait'
require 'openssl'
require 'uri'
require 'websocket/driver'

module SurrealDB
  module Connections
    # WebSocket transport for SurrealDB RPC.
    #
    # Uses websocket-driver for protocol handling and a background reader thread
    # to route responses by request ID. Supports live query notifications.
    #
    # ## Thread Safety
    #
    # A single WebSocket connection is NOT safe for concurrent use from multiple
    # threads without external synchronization. Frame writes are serialized via an
    # internal write mutex to prevent corruption, but the request/response lifecycle
    # (encode -> send -> wait -> decode) is not atomic. If you need concurrent
    # access, use a separate Client per thread or wrap calls in your own Mutex.
    #
    # ## Fiber Scheduler Compatibility
    #
    # Response waiting uses ConditionVariable#wait which is compatible with Ruby's
    # Fiber scheduler (Ruby 3.1+). This means the SDK works transparently with
    # the `async` gem and similar frameworks.
    class WebSocket < Base
      include WebSocketConnect
      include WebSocketStreams

      # @return [Integer] response timeout in seconds
      attr_reader :timeout

      # @return [Numeric] how long opening the connection (TCP connect, TLS
      #   and the WebSocket handshake together) may take, in seconds
      attr_reader :connect_timeout

      def initialize(url, **options)
        super
        @timeout = options.fetch(:timeout, SurrealDB.configuration.timeout)
        @connect_timeout = options.fetch(:connect_timeout, @timeout)
        @pending = {}
        @streams = {}
        @live_handlers = {}
        @mutex = Mutex.new
        @write_mutex = Mutex.new
        @socket = nil
        @driver = nil
        @reader_thread = nil
        @on_disconnect = nil
      end

      # Registers a callback run (on its own thread) when the connection is
      # lost without {#close} having been called.
      # @yield [String] why the connection was lost
      def on_disconnect(&block)
        @on_disconnect = block
      end

      # Opens the connection. The TCP connect, the TLS handshake and the
      # WebSocket handshake share one deadline of `connect_timeout` seconds.
      # @raise [ConnectionError] if the server cannot be reached in time
      def connect
        uri = URI.parse(@url)
        deadline = monotonic_now + @connect_timeout
        @socket = open_socket(uri, deadline)
        ws_url = build_ws_url(uri)

        @wrapper = SocketWrapper.new(@socket, ws_url)
        @driver = ::WebSocket::Driver.client(@wrapper, protocols: ['cbor'])
        setup_driver_handlers

        begin
          send_upgrade(deadline)
          wait_for_open(deadline)
        rescue StandardError
          @socket&.close
          @socket = nil
          raise
        end

        @connected = true
        @streaming_unavailable = false # the new connection may reach another server
        start_reader
        log(:debug, "WebSocket connected to #{@url}")
      end

      def close
        was_connected = @connected
        @connected = false
        @driver&.close if was_connected
        close_socket # unblocks the reader, which is waiting in readpartial
        shutdown_reader

        notify_pending_closed
        log(:debug, 'WebSocket connection closed') if was_connected
      end

      def supports_live_queries?
        true
      end

      def supports_streaming?
        !@streaming_unavailable
      end

      # Registers a handler for live query notifications.
      # @param live_query_id [String]
      # @param handler [Proc, Queue] receives notification hashes
      def on_notification(live_query_id, handler)
        @mutex.synchronize { @live_handlers[live_query_id] = handler }
      end

      # Removes a live query notification handler.
      # @param live_query_id [String]
      def remove_notification_handler(live_query_id)
        @mutex.synchronize { @live_handlers.delete(live_query_id) }
      end

      protected

      def execute(method, params, session: nil, txn: nil, timeout: nil)
        raise NotConnectedError, 'not connected' unless @connected

        id, encoded = @rpc.encode_request(method, params, session: session, txn: txn)
        entry = { result: nil, cv: ConditionVariable.new }

        @mutex.synchronize { @pending[id] = entry }

        timeout ||= @timeout
        deadline = monotonic_now + timeout
        begin
          write_frame(encoded, deadline, method)
          wait_for_response(entry, deadline, timeout)
        ensure
          @mutex.synchronize { @pending.delete(id) }
        end
      end

      private

      def build_ws_url(uri)
        path = uri.path.empty? ? '/rpc' : uri.path
        port_str = uri.port ? ":#{uri.port}" : ''
        "#{uri.scheme}://#{uri.host}#{port_str}#{path}"
      end

      def setup_driver_handlers
        @open_cv = ConditionVariable.new
        @open_result = nil

        @driver.on :open do
          @mutex.synchronize do
            @open_result = :open
            @open_cv.signal
          end
        end

        @driver.on :error do |event|
          @mutex.synchronize do
            @open_result = [:error, event.message]
            @open_cv.signal
          end
        end

        @driver.on :message do |event|
          handle_message(event.data)
        end

        @driver.on :close do
          connection_lost('closed by the server')
        end
      end

      # The upgrade request is written within the connect deadline too: a
      # peer that does not read would otherwise block the write.
      def send_upgrade(deadline)
        @wrapper.deadline = deadline
        @driver.start
      rescue SocketWrapper::WriteTimeout
        raise ConnectionError, "WebSocket handshake timed out after #{@connect_timeout}s"
      rescue SystemCallError, IOError, OpenSSL::SSL::SSLError => e
        raise ConnectionError, "WebSocket handshake failed: #{e.class}: #{e.message}"
      ensure
        @wrapper.deadline = nil
      end

      def wait_for_open(deadline)
        loop do
          data = read_handshake(deadline)
          raise ConnectionError, 'connection closed during handshake' if data.nil? || data.empty?

          @driver.parse(data)

          @mutex.synchronize do
            case @open_result
            when :open then return
            when Array then raise ConnectionError, "WebSocket handshake failed: #{@open_result[1]}"
            end
          end
        end
      end

      # Reads handshake data with the time left, never blocking in a read: a
      # server that accepts the connection but never answers the upgrade
      # would otherwise hang connect forever. Over TLS the TCP socket can be
      # readable with only part of a TLS record, on which a blocking read
      # would wait for the rest, so the SSL socket is read without blocking.
      # The deadline is checked before every read too, as a server that keeps
      # sending part of an answer never makes a read wait.
      def read_handshake(deadline)
        loop do
          remaining(deadline, 'WebSocket handshake')
          return @socket.read_nonblock(16_384)
        rescue IO::WaitReadable
          wait_for_handshake(:wait_readable, deadline)
        rescue IO::WaitWritable
          wait_for_handshake(:wait_writable, deadline)
        rescue EOFError
          return nil
        rescue SystemCallError, OpenSSL::SSL::SSLError => e
          raise ConnectionError, "WebSocket handshake failed: #{e.class}: #{e.message}"
        end
      end

      def wait_for_handshake(direction, deadline)
        return if @socket.to_io.public_send(direction, remaining(deadline, 'WebSocket handshake'))

        raise ConnectionError, "WebSocket handshake timed out after #{@connect_timeout}s"
      end

      def start_reader
        @reader_thread = Thread.new do
          Thread.current.report_on_exception = false
          reader_loop
        end
      end

      def reader_loop
        while @connected
          data = read_socket
          if data.nil? || data.empty?
            connection_lost('closed by the peer')
            break
          end
          @driver.parse(data)
        end
      rescue IOError, SystemCallError, OpenSSL::SSL::SSLError => e
        log(:warn, "WebSocket reader terminated: #{e.class}: #{e.message}") if @connected
        connection_lost("#{e.class}: #{e.message}")
      end

      # Marks the connection dead, fails the requests waiting on it, and tells
      # whoever asked (see {#on_disconnect}). Does nothing after {#close}.
      def connection_lost(reason)
        return unless @connected

        @connected = false
        close_socket
        notify_pending_closed
        callback = @on_disconnect
        Thread.new { callback.call(reason) } if callback
      end

      def close_socket
        @socket&.close
      rescue IOError, SystemCallError
        nil
      ensure
        @socket = nil
      end

      def read_socket
        socket = @socket
        return nil unless socket

        socket.readpartial(16_384)
      rescue EOFError
        nil
      end

      def handle_message(data)
        bytes = data.is_a?(Array) ? data.pack('C*') : data.b

        raw = ::CBOR.decode(bytes)
        id = raw['id']

        dispatch_notification(raw) unless id && deliver_response(id, bytes)
      rescue StandardError => e
        log(:warn, "Dropped malformed WebSocket message: #{e.class}: #{e.message}")
      end

      # Hands a response to the request or stream waiting for it.
      # @return [Boolean] false when nothing is waiting for that id
      def deliver_response(id, bytes)
        stream = nil
        delivered = @mutex.synchronize do
          stream = @streams[id]
          next true if stream

          entry = @pending[id]
          next false unless entry

          entry[:result] = bytes
          entry[:cv].signal
          true
        end
        # Outside the mutex: feeding a stream can wait for its reader.
        feed_stream(id, stream, bytes) if stream
        delivered
      end

      def dispatch_notification(raw) # rubocop:disable Metrics/CyclomaticComplexity
        result = raw['result'] || raw
        return unless result.is_a?(Hash)

        resolved = CBOR::Decoder.resolve(result)
        live_id = resolved['id']&.to_s
        action = resolved['action']
        return unless live_id && action

        handler = @mutex.synchronize { @live_handlers[live_id] }
        return unless handler

        case handler
        when Queue then handler.push(resolved)
        when Proc  then handler.call(resolved)
        end
      end

      def shutdown_reader
        thread = @reader_thread
        @reader_thread = nil
        return if thread.nil? || thread == Thread.current

        thread.join(2)
        thread.kill if thread.alive?
      end

      # Signals :closed on every pending request so blocked callers
      # fail fast instead of waiting for the full timeout.
      def notify_pending_closed
        @mutex.synchronize do
          @pending.each_value do |entry|
            entry[:result] = :closed
            entry[:cv].signal
          end
          @pending.clear
          @streams.each_value { |frames| frames.fail(ConnectionError.new('connection closed')) }
          @streams.clear
        end
      end

      # Waits for the reader thread to deliver a response into the entry,
      # using ConditionVariable for Fiber-scheduler-compatible blocking.
      # Waits for the response until the request's deadline, which writing
      # the request has already used part of.
      def wait_for_response(entry, deadline, timeout)
        result = @mutex.synchronize do
          while entry[:result].nil?
            remaining = deadline - monotonic_now
            raise TimeoutError, "request timed out after #{timeout}s" if remaining <= 0

            entry[:cv].wait(@mutex, remaining)
          end
          entry[:result]
        end

        raise ConnectionError, 'connection closed' if result == :closed

        response = @rpc.decode_response(result)
        Protocol::Response.extract_result(response)
      end

      # A frame the socket refused was not sent, so the request is safe to
      # send again: report it as NotConnectedError, not as an interruption.
      # Writing counts against the request's deadline. A frame that could
      # not be written in time was not received whole, so the server did
      # not run it; but part of it may have gone out, which leaves the
      # connection unusable.
      def write_frame(encoded, deadline, method)
        @write_mutex.synchronize do
          @wrapper.deadline = deadline
          @driver.binary(encoded)
        ensure
          @wrapper.deadline = nil
        end
      rescue SocketWrapper::WriteTimeout
        connection_lost('write timed out')
        raise TimeoutError.new("'#{method}' timed out while it was being sent", sent: false)
      rescue IOError, SystemCallError, OpenSSL::SSL::SSLError => e
        connection_lost("write failed: #{e.class}: #{e.message}")
        raise NotConnectedError, "not connected (#{e.message})"
      end
    end
  end
end
