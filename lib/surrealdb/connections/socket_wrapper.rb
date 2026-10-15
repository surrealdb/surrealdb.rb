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

        # The deadline is checked before every write: a peer that keeps
        # taking a little at a time never makes a write wait.
        until data.empty?
          time_left
          written = @socket.write_nonblock(data, exception: false)
          case written
          when :wait_writable, :wait_readable then wait(written)
          else data = data.byteslice(written..)
          end
        end
      end

      private

      def wait(readiness)
        raise WriteTimeout unless @socket.to_io.public_send(readiness, time_left)
      end

      def time_left
        left = @deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise WriteTimeout if left <= 0

        left
      end
    end
  end
end
