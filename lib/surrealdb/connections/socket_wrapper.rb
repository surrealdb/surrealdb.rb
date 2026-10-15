# frozen_string_literal: true

require 'io/wait'

module SurrealDB
  module Connections
    # Minimal wrapper that gives websocket-driver the interface it expects:
    # #url for the request URL, and #write for sending bytes. A write with
    # a deadline set gives up at the deadline.
    class SocketWrapper
      # The deadline passed with part of the data still unwritten.
      class WriteTimeout < StandardError; end

      attr_reader :url

      # @return [Float, nil] monotonic clock reading writes must finish by
      attr_accessor :deadline

      def initialize(socket, url)
        @socket = socket
        @url = url
        @deadline = nil
      end

      def write(data)
        return @socket.write(data) if @deadline.nil?

        until data.empty?
          written = @socket.write_nonblock(data, exception: false)
          case written
          when :wait_writable, :wait_readable then wait(written)
          else data = data.byteslice(written..)
          end
        end
      end

      private

      def wait(readiness)
        left = @deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise WriteTimeout if left <= 0 || !@socket.to_io.public_send(readiness, left)
      end
    end
  end
end
