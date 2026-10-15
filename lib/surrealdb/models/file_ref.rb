# frozen_string_literal: true

module SurrealDB
  # A pointer to a file in a SurrealDB bucket (`f"bucket:/key"`).
  #
  # Encoded and decoded as CBOR tag 55 carrying `[bucket, key]`.
  class FileRef
    # SurrealQL file literals allow only these characters, with no escapes
    # (and no `/` in the bucket).
    LITERAL_BUCKET = /\A[A-Za-z0-9_.-]+\z/
    LITERAL_KEY = %r{\A[A-Za-z0-9_./-]+\z}

    # @return [String]
    attr_reader :bucket

    # @return [String]
    attr_reader :key

    # @param bucket [String]
    # @param key [String] path within the bucket, e.g. "/avatars/alice.png"
    def initialize(bucket, key)
      raise ArgumentError, 'bucket must be a non-empty string' if bucket.nil? || bucket.to_s.empty?

      @bucket = bucket.to_s.freeze
      @key = key.to_s.start_with?('/') ? key.to_s.freeze : "/#{key}".freeze
    end

    # The file as SurrealQL writes it, for display. It is a valid literal
    # only when {#literal?}; to put any other file in a query, pass it as a
    # query variable, which sends it exactly.
    # @return [String]
    def to_s
      "f\"#{@bucket}:#{@key}\""
    end

    # Whether {#to_s} is a SurrealQL file literal that names this file.
    # @return [Boolean]
    def literal?
      @bucket.match?(LITERAL_BUCKET) && @key.match?(LITERAL_KEY)
    end

    def inspect
      "SurrealDB::FileRef(#{@bucket}:#{@key})"
    end

    def ==(other)
      other.is_a?(FileRef) && other.bucket == @bucket && other.key == @key
    end
    alias eql? ==

    def hash
      [self.class, @bucket, @key].hash
    end
  end
end
