# frozen_string_literal: true

require 'cbor'
require 'bigdecimal'
require 'time'

module SurrealDB
  module CBOR
    module Decoder
      module_function

      # Decodes CBOR bytes to Ruby objects, converting SurrealDB custom tags
      # to the appropriate Ruby types.
      # @param data [String] CBOR-encoded binary string
      # @return [Object] decoded Ruby object
      def decode(data)
        raw = ::CBOR.decode(data)
        resolve(raw)
      end

      # Recursively resolves CBOR::Tagged values to SurrealDB types.
      # @param obj [Object]
      # @return [Object]
      def resolve(obj)
        case obj
        when ::CBOR::Tagged
          resolve_tag(obj.tag, obj.value)
        when Hash
          obj.transform_values { |v| resolve(v) }
        when Array
          obj.map { |v| resolve(v) }
        else
          obj
        end
      end

      # Maps a CBOR tag number + value to the appropriate SurrealDB type.
      def resolve_tag(tag, value) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity
        case tag
        when Tags::NONE                 then SurrealDB::NONE
        when Tags::TABLE                then SurrealDB::Table.new(value)
        when Tags::RECORD_ID            then decode_record_id(value)
        when Tags::UUID_STRING, Tags::UUID_BINARY then resolve_uuid(tag, value)
        when Tags::DATETIME_STRING      then Time.iso8601(value).utc
        when Tags::FILE                 then SurrealDB::FileRef.new(value[0], value[1])
        when Tags::SET                  then ::Set.new(value.map { |v| resolve(v) })
        when Tags::DECIMAL_STRING       then BigDecimal(value)
        when Tags::DATETIME_COMPACT     then Time.at(value[0], value[1], :nanosecond).utc
        when Tags::DURATION_STRING      then SurrealDB::Duration.parse(value)
        when Tags::DURATION_COMPACT     then SurrealDB::Duration.new(value[0], value[1])
        when Tags::RANGE                then decode_range(value)
        when Tags::BOUND_INCLUDED       then SurrealDB::BoundIncluded.new(resolve(value))
        when Tags::BOUND_EXCLUDED       then SurrealDB::BoundExcluded.new(resolve(value))
        when Tags::GEOMETRY_POINT       then decode_point(value)
        when Tags::GEOMETRY_LINE        then decode_line(value)
        when Tags::GEOMETRY_POLYGON     then decode_polygon(value)
        when Tags::GEOMETRY_MULTIPOINT  then decode_multipoint(value)
        when Tags::GEOMETRY_MULTILINE   then decode_multiline(value)
        when Tags::GEOMETRY_MULTIPOLYGON then decode_multipolygon(value)
        when Tags::GEOMETRY_COLLECTION then decode_collection(value)
        else
          value
        end
      end

      # The string form ("table:id") is the one StringRecordID sends.
      def decode_record_id(value)
        return SurrealDB::StringRecordID.new(value) if value.is_a?(String)

        SurrealDB::RecordID.new(value[0], resolve(value[1]))
      end

      def resolve_uuid(tag, value)
        if tag == Tags::UUID_BINARY && value.bytesize == 16
          SurrealDB::Uuid.new(value)
        else
          SurrealDB::Uuid.parse(value)
        end
      end

      def decode_range(value)
        SurrealDB::Range.new(resolve(value[0]), resolve(value[1]))
      end

      def decode_point(coords)
        SurrealDB::GeometryPoint.new(coords[0], coords[1])
      end

      def decode_line(coords_array)
        points = coords_array.map { |c| SurrealDB::GeometryPoint.new(c[0], c[1]) }
        SurrealDB::GeometryLine.new(*points)
      end

      def decode_polygon(rings)
        exterior = decode_line(rings[0])
        interiors = rings[1..].map { |r| decode_line(r) }
        SurrealDB::GeometryPolygon.new(exterior, *interiors)
      end

      def decode_multipoint(coords_array)
        points = coords_array.map { |c| SurrealDB::GeometryPoint.new(c[0], c[1]) }
        SurrealDB::GeometryMultiPoint.new(*points)
      end

      def decode_multiline(lines_array)
        lines = lines_array.map { |coords| decode_line(coords) }
        SurrealDB::GeometryMultiLine.new(*lines)
      end

      def decode_multipolygon(polygons_array)
        polygons = polygons_array.map { |rings| decode_polygon(rings) }
        SurrealDB::GeometryMultiPolygon.new(*polygons)
      end

      def decode_collection(geometries)
        SurrealDB::GeometryCollection.new(*geometries.map { |g| resolve(g) })
      end

      private_class_method :resolve_tag, :decode_record_id, :resolve_uuid, :decode_range,
                           :decode_point, :decode_line, :decode_polygon,
                           :decode_multipoint, :decode_multiline,
                           :decode_multipolygon, :decode_collection
    end
  end
end
