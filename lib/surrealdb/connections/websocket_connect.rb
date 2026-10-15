# frozen_string_literal: true

module SurrealDB
  module Connections
    # Opening the socket for {WebSocket}: the DNS lookup, the TCP connect to
    # each address in turn and the TLS handshake, all within one deadline of
    # `connect_timeout` seconds.
    module WebSocketConnect
      private

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
      # An address can also time out on its own (the OS gives up on it)
      # before the deadline; the next one gets the time left.
      def tcp_connect(host, port, deadline)
        error = nil
        resolve(host, port, deadline).each do |addr|
          left = deadline - monotonic_now
          break if left <= 0

          return addr.connect(timeout: left)
        rescue SystemCallError, IO::TimeoutError => e
          error = e
        end
        raise tcp_connect_error(host, port, error, monotonic_now >= deadline)
      end

      def tcp_connect_error(host, port, error, out_of_time)
        timed_out = out_of_time || error.is_a?(Errno::ETIMEDOUT) || error.is_a?(IO::TimeoutError)
        return ConnectionError.new("TCP connect to #{host}:#{port} timed out after #{@connect_timeout}s") if timed_out

        ConnectionError.new("cannot connect to #{host}:#{port}: #{error&.message || 'no addresses'}")
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
    end
  end
end
