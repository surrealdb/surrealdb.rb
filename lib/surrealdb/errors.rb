# frozen_string_literal: true

module SurrealDB
  class Error < StandardError; end

  class ConnectionError < Error; end

  # A request was not sent because the connection was down. Unlike other
  # ConnectionErrors, it is always safe to send it again.
  class NotConnectedError < ConnectionError; end

  # The connection was lost while a request was in flight, so the request
  # may or may not have run. Raised instead of retrying requests that are
  # not safe to repeat (queries, writes, transactions).
  class RequestInterruptedError < ConnectionError; end

  # A request did not finish in time. {#sent?} says whether it may have
  # reached the server: it is false when the time ran out before the request
  # was sent (waiting for a reconnect, renewing the access token, opening a
  # connection, writing the request).
  class TimeoutError < Error
    def initialize(message = nil, sent: true)
      @sent = sent
      super(message)
    end

    # @return [Boolean] whether the request may have reached the server
    def sent?
      @sent
    end
  end

  class ProtocolError < Error; end

  # Raised when a feature is unavailable on the current transport
  # (e.g. live queries on HTTP).
  class UnsupportedError < Error; end

  # Raised when a closed session is used.
  class SessionError < Error; end

  # Raised when a committed or cancelled transaction is used.
  class TransactionError < Error; end

  # Raised by {ApiResponse#value} for a response outside 2xx.
  class ApiError < Error
    # @return [ApiResponse]
    attr_reader :response

    def initialize(method, path, response)
      @response = response
      super("#{method.to_s.upcase} #{path} answered #{response.status}: #{response.body.inspect}")
    end
  end

  # A session's credentials expired, or were lost with the connection, and
  # could not be renewed. The request was not sent, rather than running it
  # without the identity the caller expects.
  class AuthenticationError < Error; end

  # Raised by {Client#connect} when the server's version is outside the
  # range this SDK supports (see {ServerVersion}).
  class UnsupportedVersionError < Error
    # @return [String] the version the server reported
    attr_reader :version

    # @return [String] the oldest supported version
    attr_reader :minimum

    # @return [String] the first unsupported version
    attr_reader :maximum

    def initialize(version, minimum, maximum)
      @version = version
      @minimum = minimum
      @maximum = maximum
      super("SurrealDB server version #{version} is not supported: this SDK supports #{minimum} " \
            "up to (not including) #{maximum}. Pass version_check: false to connect anyway.")
    end
  end

  # Base class for errors returned by the SurrealDB server.
  # Supports both legacy (code + message) and v3 structured
  # (kind + details + cause chain) error formats.
  class ServerError < Error
    # @return [Integer, nil] JSON-RPC error code
    attr_reader :code

    # @return [String, nil] structured error kind (e.g. "NotFound", "NotAllowed")
    attr_reader :kind

    # @return [Hash, nil] additional error details
    attr_reader :details

    # @return [ServerError, nil] chained cause from the server
    attr_reader :server_cause

    def initialize(message = nil, code: nil, kind: nil, details: nil, server_cause: nil)
      @code = code
      @kind = kind
      @details = details
      @server_cause = server_cause
      super(message)
    end

    # Walk the cause chain looking for a specific kind.
    # @param target_kind [String]
    # @return [ServerError, nil]
    def find_cause(target_kind)
      current = self
      while current
        return current if current.kind == target_kind

        current = current.server_cause
      end
      nil
    end

    # @param target_kind [String]
    # @return [Boolean]
    def has_kind?(target_kind) # rubocop:disable Naming/PredicatePrefix
      !find_cause(target_kind).nil?
    end

    # Populated after subclasses are defined at the bottom of this file.
    KIND_TO_CLASS = {} # rubocop:disable Style/MutableConstant

    # Builds the appropriate ServerError subclass from a parsed error hash.
    # @param data [Hash] parsed error data with string keys
    # @return [ServerError]
    def self.from_response(data)
      return new(data.to_s) unless data.is_a?(Hash)

      kind = data['kind']
      message = data['message'] || data['msg']
      code = data['code']
      details = data['details']

      raw_cause = data['cause']
      cause = raw_cause.is_a?(Hash) ? from_response(raw_cause) : nil

      klass = KIND_TO_CLASS.fetch(kind, self)
      klass.new(message, code: code, kind: kind, details: details, server_cause: cause)
    end
  end

  class QueryError < ServerError; end
  class NotFoundError < ServerError; end
  class NotAllowedError < ServerError; end
  class AlreadyExistsError < ServerError; end
  class ValidationError < ServerError; end
  class InternalServerError < ServerError; end
  class SerializationError < ServerError; end
  class ConfigurationError < ServerError; end
  class ThrownError < ServerError; end

  ServerError::KIND_TO_CLASS.merge!(
    'Query' => QueryError,
    'NotFound' => NotFoundError,
    'NotAllowed' => NotAllowedError,
    'AlreadyExists' => AlreadyExistsError,
    'Validation' => ValidationError,
    'Internal' => InternalServerError,
    'Serialization' => SerializationError,
    'Configuration' => ConfigurationError,
    'Thrown' => ThrownError
  ).freeze

  # Raised when statements of an import failed. The statements that did not
  # fail have still been applied: an import is not atomic.
  class ImportError < Error
    # @return [Array<ServerError>] the failures (at most 100 are kept)
    attr_reader :failures

    # @return [Integer] how many statements failed
    attr_reader :count

    # @param failures [Array<ServerError>]
    # @param count [Integer]
    def initialize(failures, count = failures.length)
      @failures = failures
      @count = count
      first = failures.first&.message
      super("#{count} statement#{'s' unless count == 1} of the import failed#{": #{first}" if first}")
    end
  end
end
