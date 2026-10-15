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

        @driver = ::WebSocket::Driver.client(SocketWrapper.new(@socket, ws_url), protocols: ['cbor'])
        setup_driver_handlers

        @driver.start

        begin
          wait_for_open(deadline)
        rescue StandardError
          @socket&.close
          @socket = nil
          raise
        end

        @connected = true
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

      def execute(method, params, session: nil, txn: nil)
        raise NotConnectedError, 'not connected' unless @connected

        id, encoded = @rpc.encode_request(method, params, session: session, txn: txn)
        entry = { result: nil, cv: ConditionVariable.new }

        @mutex.synchronize { @pending[id] = entry }

        begin
          write_frame(encoded)
          wait_for_response(entry)
        ensure
          @mutex.synchronize { @pending.delete(id) }
        end
      end

      private

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def remaining(deadline, what)
        left = deadline - monotonic_now
        raise ConnectionError, "#{what} timed out after #{@connect_timeout}s" if left <= 0

        left
      end

      def open_socket(uri, deadline)
        port = uri.port || default_port(uri.scheme)
        tcp = tcp_connect(uri.host, port, deadline)
        return tcp unless uri.scheme == 'wss'

        tls_connect(tcp, uri.host, deadline)
      end

      # Resolves the host, then tries its addresses in turn, all within the
      # one deadline. (Socket.tcp gives each address its own connect_timeout
      # and does not bound the lookup on every platform.)
      def tcp_connect(host, port, deadline)
        error = nil
        resolve(host, port, deadline).each do |addr|
          return addr.connect(timeout: remaining(deadline, 'TCP connect'))
        rescue Errno::ETIMEDOUT, IO::TimeoutError
          raise ConnectionError, "TCP connect to #{host}:#{port} timed out after #{@connect_timeout}s"
        rescue SystemCallError => e
          error = e
        end
        raise ConnectionError, "cannot connect to #{host}:#{port}: #{error&.message || 'no addresses'}"
      end

      # getaddrinfo cannot be interrupted, so the lookup runs in a thread
      # that is left to finish on its own if the deadline passes first.
      def resolve(host, port, deadline)
        lookup = Thread.new { Addrinfo.getaddrinfo(host, port, nil, :STREAM) }
        lookup.report_on_exception = false
        return lookup.value if lookup.join(remaining(deadline, 'DNS lookup'))

        raise ConnectionError, "DNS lookup of #{host} timed out after #{@connect_timeout}s"
      rescue SocketError => e
        raise ConnectionError, "cannot connect to #{host}:#{port}: #{e.message}"
      end

      def tls_connect(tcp, host, deadline)
        ctx = OpenSSL::SSL::SSLContext.new
        ctx.verify_mode = OpenSSL::SSL::VERIFY_PEER
        ctx.cert_store = OpenSSL::X509::Store.new.tap(&:set_default_paths)
        ssl = OpenSSL::SSL::SSLSocket.new(tcp, ctx)
        ssl.hostname = host
        ssl.sync_close = true
        loop do
          ssl.connect_nonblock
          return ssl
        rescue IO::WaitReadable
          tcp.wait_readable(remaining(deadline, 'TLS handshake'))
        rescue IO::WaitWritable
          tcp.wait_writable(remaining(deadline, 'TLS handshake'))
        end
      rescue OpenSSL::SSL::SSLError, SystemCallError => e
        tcp.close
        raise ConnectionError, "TLS handshake with #{host} failed: #{e.message}"
      rescue ConnectionError
        tcp.close
        raise
      end

      def default_port(scheme)
        scheme == 'wss' ? 443 : 80
      end

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
      def read_handshake(deadline)
        loop do
          return @socket.read_nonblock(16_384)
        rescue IO::WaitReadable
          wait_for_handshake(:wait_readable, deadline)
        rescue IO::WaitWritable
          wait_for_handshake(:wait_writable, deadline)
        rescue EOFError
          return nil
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

        if id
          delivered = @mutex.synchronize do
            entry = @pending[id]
            if entry
              entry[:result] = bytes
              entry[:cv].signal
              true
            end
          end
          dispatch_notification(raw) unless delivered
        else
          dispatch_notification(raw)
        end
      rescue StandardError => e
        log(:warn, "Dropped malformed WebSocket message: #{e.class}: #{e.message}")
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
        end
      end

      # Waits for the reader thread to deliver a response into the entry,
      # using ConditionVariable for Fiber-scheduler-compatible blocking.
      def wait_for_response(entry)
        result = @mutex.synchronize do
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @timeout
          while entry[:result].nil?
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            raise TimeoutError, "request timed out after #{@timeout}s" if remaining <= 0

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
      def write_frame(encoded)
        @write_mutex.synchronize { @driver.binary(encoded) }
      rescue IOError, SystemCallError, OpenSSL::SSL::SSLError => e
        connection_lost("write failed: #{e.class}: #{e.message}")
        raise NotConnectedError, "not connected (#{e.message})"
      end

      # Minimal wrapper that gives websocket-driver the interface it expects:
      # #url for the request URL, and #write for sending bytes.
      class SocketWrapper
        attr_reader :url

        def initialize(socket, url)
          @socket = socket
          @url = url
        end

        def write(data)
          @socket.write(data)
        end
      end
    end
  end
end
