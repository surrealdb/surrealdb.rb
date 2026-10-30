# frozen_string_literal: true

module SurrealDB
  # A number of one of SurrealDB 4.0's sized kinds: i8, u8, i16, u16, i32,
  # u32, u64, f16 or f32.
  #
  # The kinds travel as themselves only over `cbor.2`, which the client
  # negotiates with a 4.0 server. Over plain `cbor` (any server before 4.0,
  # and embedded connections) a sized number is sent widened, as the server
  # widens it: an Integer, a Float, or a BigDecimal for a u64 above the
  # signed 64-bit range.
  #
  # A plain Integer or Float is always sent as SurrealDB's int or float; build
  # a SizedNumber to send a sized kind:
  #
  #   SurrealDB::SizedNumber.u8(5)
  #   SurrealDB::SizedNumber.f32(0.1) # rounded to the nearest f32
  class SizedNumber
    INTEGER_RANGES = {
      i8: (-(2**7))..((2**7) - 1),
      u8: 0..((2**8) - 1),
      i16: (-(2**15))..((2**15) - 1),
      u16: 0..((2**16) - 1),
      i32: (-(2**31))..((2**31) - 1),
      u32: 0..((2**32) - 1),
      u64: 0..((2**64) - 1)
    }.freeze

    FLOAT_KINDS = %i[f16 f32].freeze

    KINDS = (INTEGER_RANGES.keys + FLOAT_KINDS).freeze

    # The magnitude from which an f16 rounds to infinity: halfway between the
    # largest finite f16 (65504) and the next power of two, ties to even.
    F16_OVERFLOW = 65_520.0

    # @return [Symbol] one of {KINDS}
    attr_reader :kind

    # @return [Integer, Float]
    attr_reader :value

    KINDS.each do |kind|
      define_singleton_method(kind) { |value| new(kind, value) }
    end

    # @param kind [Symbol] one of {KINDS}
    # @param value [Integer, Float] an Integer within the kind's range for
    #   the integer kinds; any Numeric for f16 and f32, rounded to the kind
    # @raise [ArgumentError] for an unknown kind
    # @raise [TypeError] for a non-Integer value of an integer kind
    # @raise [RangeError] for an integer outside the kind's range
    def initialize(kind, value)
      @kind = kind
      @value = if INTEGER_RANGES.key?(kind)
                 self.class.check_integer(kind, value)
               elsif FLOAT_KINDS.include?(kind)
                 self.class.round(kind, Float(value))
               else
                 raise ArgumentError, "unknown number kind #{kind.inspect}; expected one of #{KINDS.join(', ')}"
               end
      freeze
    end

    # @return [Boolean] true for f16 and f32
    def float?
      FLOAT_KINDS.include?(kind)
    end

    # @return [Boolean] true for the integer kinds
    def integer?
      !float?
    end

    def to_i
      value.to_i
    end

    def to_f
      value.to_f
    end

    # The SurrealQL literal, such as `5u8` or `1.5f32`.
    def to_s
      return "<#{kind}>#{value}" if float? && (value.nan? || value.infinite?)

      "#{value}#{kind}"
    end

    def inspect
      "SurrealDB::SizedNumber(#{self})"
    end

    # Equal to a SizedNumber of the same kind and value, never to a plain
    # Integer or Float: the kind is part of the value. NaN equals NaN.
    def ==(other)
      other.is_a?(SizedNumber) && kind == other.kind &&
        (value == other.value || (float? && value.nan? && other.value.nan?))
    end
    alias eql? ==

    def hash
      [self.class, kind, float? && value.nan? ? :nan : value].hash
    end

    class << self
      # @return [Integer]
      def check_integer(kind, value)
        raise TypeError, "#{kind} needs an Integer, got #{value.inspect}" unless value.is_a?(Integer)

        range = INTEGER_RANGES.fetch(kind)
        raise RangeError, "#{value} is outside the #{kind} range #{range}" unless range.cover?(value)

        value
      end

      # Rounds a Float to the nearest value of the kind, ties to even.
      # @return [Float]
      def round(kind, float)
        return [float].pack('e').unpack1('e') if kind == :f32

        round_f16(float)
      end

      # @return [Boolean] whether the kind holds the Float exactly
      def exact?(kind, float)
        float.nan? || round(kind, float) == float
      end

      private

      # Half precision has an 11-bit significand and exponents from -14
      # (below which it is subnormal, in steps of 2**-24) up to 15.
      def round_f16(float)
        return float unless float.finite? && !float.zero?
        return float.positive? ? Float::INFINITY : -Float::INFINITY if float.abs >= F16_OVERFLOW

        exponent = Math.frexp(float.abs)[1] - 1
        quantum = 2.0**([exponent, -14].max - 10)
        rounded = (float / quantum).round(half: :even) * quantum
        # A value that rounds to zero keeps its sign, as an IEEE conversion does.
        rounded.zero? && float.negative? ? -0.0 : rounded.to_f
      end
    end
  end
end
