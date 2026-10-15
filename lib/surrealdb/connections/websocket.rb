# frozen_string_literal: true

require 'socket'
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

      def initialize(url, **options)
        super
        @timeout = options.fetch(:timeout, SurrealDB.configuration.timeout)
        @pending = {}
        @live_handlers = {}
        @mutex = Mutex.new
        @write_mutex = Mutex.new
        @socket = nil
        @driver = nil
        @reader_thread = nil
      end

      def connect
        uri = URI.parse(@url)
        @socket = open_socket(uri)
        ws_url = build_ws_url(uri)

        @driver = ::WebSocket::Driver.client(SocketWrapper.new(@socket, ws_url), protocols: ['cbor'])
        setup_driver_handlers

        @driver.start

        wait_for_open

        @connected = true
        start_reader
        log(:debug, "WebSocket connected to #{@url}")
      end

      def close
        return unless @connected

        @connected = false
        @driver&.close
        shutdown_reader
        @socket&.close
        @socket = nil

        notify_pending_closed
        log(:debug, 'WebSocket connection closed')
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

      def execute(method, params, session: nil)
        raise ConnectionError, 'not connected' unless @connected

        id, encoded = @rpc.encode_request(method, params, session: session)
        entry = { result: nil, cv: ConditionVariable.new }

        @mutex.synchronize { @pending[id] = entry }

        begin
          @write_mutex.synchronize { @driver.binary(encoded) }
          wait_for_response(entry)
        ensure
          @mutex.synchronize { @pending.delete(id) }
        end
      end

      private

      def open_socket(uri)
        tcp = TCPSocket.new(uri.host, uri.port || default_port(uri.scheme))
        return tcp unless uri.scheme == 'wss'

        ctx = OpenSSL::SSL::SSLContext.new
        ctx.verify_mode = OpenSSL::SSL::VERIFY_PEER
        ctx.cert_store = OpenSSL::X509::Store.new.tap(&:set_default_paths)
        ssl = OpenSSL::SSL::SSLSocket.new(tcp, ctx)
        ssl.hostname = uri.host
        ssl.connect
        ssl
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
          @connected = false
          notify_pending_closed
        end
      end

      def wait_for_open
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @timeout

        loop do
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          raise ConnectionError, 'WebSocket handshake timed out' if remaining <= 0

          data = read_socket
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
            @connected = false
            notify_pending_closed
            break
          end
          @driver.parse(data)
        end
      rescue IOError, Errno::ECONNRESET, OpenSSL::SSL::SSLError => e
        @connected = false
        notify_pending_closed
        log(:warn, "WebSocket reader terminated: #{e.class}: #{e.message}")
      end

      def read_socket
        @socket.readpartial(16_384)
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
        @reader_thread&.join(2)
        @reader_thread&.kill if @reader_thread&.alive?
        @reader_thread = nil
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
