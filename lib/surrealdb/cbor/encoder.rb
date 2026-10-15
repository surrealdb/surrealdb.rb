# frozen_string_literal: true

require 'cbor'
require 'bigdecimal'
require 'time'

module SurrealDB
  module CBOR
    module Encoder
      module_function

      # Encodes a Ruby object to CBOR bytes with SurrealDB custom tags.
      # @param obj [Object] Ruby object to encode
      # @return [String] CBOR-encoded binary string
      def encode(obj)
        ::CBOR.encode(prepare(obj))
      end

      # Recursively converts SurrealDB types to CBOR::Tagged before encoding.
      # @param obj [Object]
      # @return [Object] CBOR-encodable representation
      def prepare(obj) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/MethodLength,Metrics/PerceivedComplexity
        case obj
        when SurrealDB::None
          ::CBOR::Tagged.new(Tags::NONE, nil)
        when SurrealDB::Table
          ::CBOR::Tagged.new(Tags::TABLE, obj.name)
        when SurrealDB::RecordID
          ::CBOR::Tagged.new(Tags::RECORD_ID, [obj.table, prepare(obj.id)])
        when SurrealDB::StringRecordID
          ::CBOR::Tagged.new(Tags::RECORD_ID, obj.value)
        when SurrealDB::Duration
          ::CBOR::Tagged.new(Tags::DURATION_COMPACT, [obj.secs, obj.nanos])
        when SurrealDB::Range
          ::CBOR::Tagged.new(Tags::RANGE, [prepare_bound(obj.begin_bound), prepare_bound(obj.end_bound)])
        when SurrealDB::BoundIncluded
          ::CBOR::Tagged.new(Tags::BOUND_INCLUDED, prepare(obj.value))
        when SurrealDB::BoundExcluded
          ::CBOR::Tagged.new(Tags::BOUND_EXCLUDED, prepare(obj.value))
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
          ::CBOR::Tagged.new(Tags::GEOMETRY_COLLECTION, obj.geometries.map { |g| prepare(g) })
        when Time
          ::CBOR::Tagged.new(Tags::DATETIME_COMPACT, [obj.to_i, obj.nsec])
        when BigDecimal
          ::CBOR::Tagged.new(Tags::DECIMAL_STRING, obj.to_s('F'))
        when Hash
          obj.transform_values { |v| prepare(v) }
        when Array
          obj.map { |v| prepare(v) }
        else
          obj
        end
      end

      def prepare_bound(bound)
        return nil if bound.nil?

        prepare(bound)
      end

      def encode_line_coords(line)
        line.points.map { |p| [p.longitude, p.latitude] }
      end

      def encode_polygon(polygon)
        rings = [encode_line_coords(polygon.exterior)]
        polygon.interiors.each { |ring| rings << encode_line_coords(ring) }
        rings
      end

      private_class_method :prepare_bound, :encode_line_coords, :encode_polygon
    end
  end
end
