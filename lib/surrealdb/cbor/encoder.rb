# frozen_string_literal: true

require 'cbor'
require 'bigdecimal'
require 'time'

module SurrealDB
  module CBOR
    module Encoder
      # SurrealDB integers are 64-bit signed: the server wraps anything larger
      # on 3.x and refuses it on 4.0, so it is never sent.
      INT64_RANGE = (-(2**63)..((2**63) - 1))

      module_function

      # Encodes a Ruby object to CBOR bytes with SurrealDB custom tags.
      # @param obj [Object] Ruby object to encode
      # @param cbor2 [Boolean] encode for `cbor.2`, which carries sized numbers
      #   as themselves; plain `cbor` widens them
      # @return [String] CBOR-encoded binary string
      def encode(obj, cbor2: false)
        ::CBOR.encode(prepare(obj, cbor2: cbor2))
      end

      # Recursively converts SurrealDB types to CBOR::Tagged before encoding.
      # @param obj [Object]
      # @param cbor2 [Boolean] see {encode}
      # @return [Object] CBOR-encodable representation
      def prepare(obj, cbor2: false) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/MethodLength,Metrics/PerceivedComplexity
        case obj
        when SurrealDB::SizedNumber
          prepare_sized(obj, cbor2)
        when SurrealDB::None
          ::CBOR::Tagged.new(Tags::NONE, nil)
        when SurrealDB::Table
          ::CBOR::Tagged.new(Tags::TABLE, obj.name)
        when SurrealDB::RecordID
          ::CBOR::Tagged.new(Tags::RECORD_ID, [obj.table, prepare(obj.id, cbor2: cbor2)])
        when SurrealDB::StringRecordID
          ::CBOR::Tagged.new(Tags::RECORD_ID, obj.value)
        when SurrealDB::Uuid
          ::CBOR::Tagged.new(Tags::UUID_BINARY, obj.bytes)
        when SurrealDB::FileRef
          ::CBOR::Tagged.new(Tags::FILE, [obj.bucket, obj.key])
        when ::Set
          ::CBOR::Tagged.new(Tags::SET, obj.map { |v| prepare(v, cbor2: cbor2) })
        when SurrealDB::Duration
          ::CBOR::Tagged.new(Tags::DURATION_COMPACT, [obj.secs, obj.nanos])
        when SurrealDB::Range
          ::CBOR::Tagged.new(Tags::RANGE, [prepare_bound(obj.begin_bound, cbor2), prepare_bound(obj.end_bound, cbor2)])
        when SurrealDB::BoundIncluded
          ::CBOR::Tagged.new(Tags::BOUND_INCLUDED, prepare(obj.value, cbor2: cbor2))
        when SurrealDB::BoundExcluded
          ::CBOR::Tagged.new(Tags::BOUND_EXCLUDED, prepare(obj.value, cbor2: cbor2))
        when SurrealDB::GeometryPoint
          ::CBOR::Tagged.new(Tags::GEOMETRY_POINT, [obj.longitude, obj.latitude])
        when SurrealDB::GeometryLine
          ::CBOR::Tagged.new(Tags::GEOMETRY_LINE, encode_line_coords(obj))
        when SurrealDB::GeometryPolygon
          ::CBOR::Tagged.new(Tags::GEOMETRY_POLYGON, encode_polygon(obj))
        when SurrealDB::GeometryMultiPoint
          ::CBOR::Tagged.new(Tags::GEOMETRY_MULTIPOINT, obj.points.map { |p| [p.longitude, p.latitude] })
        when SurrealDB::GeometryMultiLine
          ::CBOR::Tagged.new(Tags::GEOMETRY_MULTILINE, obj.lines.map { |l| encode_line_coords(l) })
        when SurrealDB::GeometryMultiPolygon
          ::CBOR::Tagged.new(Tags::GEOMETRY_MULTIPOLYGON, obj.polygons.map { |p| encode_polygon(p) })
        when SurrealDB::GeometryCollection
          ::CBOR::Tagged.new(Tags::GEOMETRY_COLLECTION, obj.geometries.map { |g| prepare(g, cbor2: cbor2) })
        when Time
          ::CBOR::Tagged.new(Tags::DATETIME_COMPACT, [obj.to_i, obj.nsec])
        when BigDecimal
          ::CBOR::Tagged.new(Tags::DECIMAL_STRING, obj.to_s('F'))
        when Integer
          prepare_integer(obj)
        when Hash
          prepare_hash(obj, cbor2)
        when Array
          obj.map { |v| prepare(v, cbor2: cbor2) }
        else
          obj
        end
      end

      # @raise [RangeError] outside the signed 64-bit range; send a BigDecimal
      #   for a number that large
      def prepare_integer(int)
        return int if INT64_RANGE.cover?(int)

        raise RangeError, "integer #{int} does not fit in 64 bits; use a BigDecimal to send a number that large"
      end

      # A Symbol key is written as text, so it must not repeat a String key:
      # an object with two entries of one name is refused by SurrealDB 4.0.
      # @raise [ArgumentError] when two keys are the same
      def prepare_hash(hash, cbor2)
        hash.each_with_object({}) do |(key, value), out|
          key = key.to_s if key.is_a?(Symbol)
          if out.key?(key)
            raise ArgumentError, "duplicate key #{key.inspect}: a Symbol and a String name the same field"
          end

          out[key] = prepare(value, cbor2: cbor2)
        end
      end

      def prepare_bound(bound, cbor2)
        return nil if bound.nil?

        prepare(bound, cbor2: cbor2)
      end

      # cbor.2 tags a sized number with its kind. Plain cbor widens it, as the
      # server does: a u64 beyond the signed 64-bit range becomes a decimal.
      def prepare_sized(number, cbor2)
        return ::CBOR::Tagged.new(Tags::SIZED_NUMBERS.fetch(number.kind), number.value) if cbor2
        return number.value if number.float? || INT64_RANGE.cover?(number.value)

        ::CBOR::Tagged.new(Tags::DECIMAL_STRING, number.value.to_s)
      end

      def encode_line_coords(line)
        line.points.map { |p| [p.longitude, p.latitude] }
      end

      def encode_polygon(polygon)
        rings = [encode_line_coords(polygon.exterior)]
        polygon.interiors.each { |ring| rings << encode_line_coords(ring) }
        rings
      end

      private_class_method :prepare_integer, :prepare_hash, :prepare_bound, :prepare_sized,
                           :encode_line_coords, :encode_polygon
    end
  end
end
