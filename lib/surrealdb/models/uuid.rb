# frozen_string_literal: true

require 'securerandom'

module SurrealDB
  # A SurrealDB UUID value.
  #
  # Encoded as CBOR tag 37 carrying the 16 raw bytes, and decoded from tag 37
  # (bytes) or tag 9 (string). Keeping UUIDs typed is what lets uuid-keyed
  # record ids and `type::is_uuid` checks survive a round trip: a plain
  # String would be stored as a string.
  class Uuid
    # Canonical (8-4-4-4-12) or compact (32 hex digits), nothing in between.
    PATTERN = /\A(?:\h{8}-\h{4}-\h{4}-\h{4}-\h{12}|\h{32})\z/

    # @return [String] the 16 raw bytes (binary encoding)
    attr_reader :bytes

    # @param bytes [String] 16 raw bytes
    def initialize(bytes)
      raise ArgumentError, "UUID must be 16 bytes, got #{bytes.to_s.bytesize}" unless bytes.to_s.bytesize == 16

      @bytes = bytes.to_s.b.freeze
    end

    # Parses the canonical text form ("0190d5ab-…"), with or without hyphens.
    # @param str [String]
    # @return [Uuid]
    # @raise [ArgumentError] if the string is not a UUID
    def self.parse(str)
      str = str.to_s
      raise ArgumentError, "invalid UUID: #{str.inspect}" unless str.match?(PATTERN)

      new([str.delete('-')].pack('H32'))
    end

    # A random (version 4) UUID.
    # @return [Uuid]
    def self.v4
      parse(SecureRandom.uuid)
    end

    # A time-ordered (version 7) UUID.
    # @return [Uuid]
    def self.v7
      ms = Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond)
      rand = SecureRandom.random_bytes(10).bytes
      rand[0] = (rand[0] & 0x0f) | 0x70 # version 7
      rand[2] = (rand[2] & 0x3f) | 0x80 # RFC 4122 variant
      new([ms >> 16, ms & 0xffff].pack('Nn') + rand.pack('C*'))
    end

    # @return [String] canonical hyphenated lower-case form
    def to_s
      hex = @bytes.unpack1('H32')
      "#{hex[0, 8]}-#{hex[8, 4]}-#{hex[12, 4]}-#{hex[16, 4]}-#{hex[20, 12]}"
    end

    def inspect
      "SurrealDB::Uuid(#{self})"
    end

    def ==(other)
      other.is_a?(Uuid) && other.bytes == @bytes
    end
    alias eql? ==

    def hash
      [self.class, @bytes].hash
    end
  end
end
