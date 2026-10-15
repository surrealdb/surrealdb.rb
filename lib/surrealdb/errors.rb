# frozen_string_literal: true

module SurrealDB
  class Error < StandardError; end

  class ConnectionError < Error; end
  class TimeoutError < Error; end
  class ProtocolError < Error; end

  # Raised when a feature is unavailable on the current transport
  # (e.g. live queries on HTTP).
  class UnsupportedError < Error; end

  # Raised when a closed session is used.
  class SessionError < Error; end

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
end
