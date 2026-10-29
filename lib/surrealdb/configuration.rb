# frozen_string_literal: true

module SurrealDB
  class Configuration
    # How long opening a connection may take, in seconds, when no
    # `:connect_timeout` is given and there is no request `timeout` to use
    # instead.
    DEFAULT_CONNECT_TIMEOUT = 30

    # @return [Numeric, nil] how long a request waits for its response, in
    #   seconds; nil (the default) waits for as long as the server takes.
    #   This is a client-side limit only: it stops the client waiting, and the
    #   server may still run the request. To stop a statement on the server,
    #   give it a `TIMEOUT` clause. It does not limit opening a connection
    #   (see the `:connect_timeout` connection option).
    attr_accessor :timeout

    # @return [Logger, nil] optional logger instance
    attr_accessor :logger

    def initialize
      @timeout = nil
      @logger = nil
    end
  end
end
