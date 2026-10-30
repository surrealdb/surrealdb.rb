# frozen_string_literal: true

require 'cbor'
require 'bigdecimal'
require 'time'

module SurrealDB
  module CBOR
    module Decoder
      INT64_RANGE = Encoder::INT64_RANGE

      module_function

      # Decodes CBOR bytes to Ruby objects, converting SurrealDB custom tags
      # to the appropriate Ruby types.
      # @param data [String] CBOR-encoded binary string
      # @param cbor2 [Boolean] decode as `cbor.2`, which carries sized numbers
      #   (tags 180 to 188); plain `cbor` refuses those tags, as the server does
      # @return [Object] decoded Ruby object
      # @raise [ProtocolError] for a sized-number tag that is not valid here
      def decode(data, cbor2: false)
        raw = ::CBOR.decode(data)
        resolve(raw, cbor2: cbor2)
      end

      # Recursively resolves CBOR::Tagged values to SurrealDB types.
      # @param obj [Object]
      # @param cbor2 [Boolean] see {decode}
      # @return [Object]
      def resolve(obj, cbor2: false)
        case obj
        when ::CBOR::Tagged
          resolve_tag(obj.tag, obj.value, cbor2)
        when Hash
          obj.transform_values { |v| resolve(v, cbor2: cbor2) }
        when Array
          obj.map { |v| resolve(v, cbor2: cbor2) }
        else
          obj
        end
      end

      # Maps a CBOR tag number + value to the appropriate SurrealDB type.
      def resolve_tag(tag, value, cbor2) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/MethodLength
        case tag
        when Tags::NONE                 then SurrealDB::NONE
        when Tags::TABLE                then SurrealDB::Table.new(value)
        when Tags::RECORD_ID            then decode_record_id(value, cbor2)
        when Tags::UUID_STRING, Tags::UUID_BINARY then resolve_uuid(tag, value)
        when Tags::DATETIME_STRING      then Time.iso8601(value).utc
        when Tags::FILE                 then SurrealDB::FileRef.new(value[0], value[1])
        when Tags::SET                  then ::Set.new(value.map { |v| resolve(v, cbor2: cbor2) })
        when Tags::DECIMAL_STRING       then BigDecimal(value)
        when Tags::DATETIME_COMPACT     then Time.at(value[0], value[1], :nanosecond).utc
        when Tags::DURATION_STRING      then SurrealDB::Duration.parse(value)
        # The server omits trailing zero fields: [] is 0s and [secs] has no nanos.
        when Tags::DURATION_COMPACT     then SurrealDB::Duration.new(value[0] || 0, value[1] || 0)
        when Tags::RANGE                then decode_range(value, cbor2)
        when Tags::BOUND_INCLUDED       then SurrealDB::BoundIncluded.new(resolve(value, cbor2: cbor2))
        when Tags::BOUND_EXCLUDED       then SurrealDB::BoundExcluded.new(resolve(value, cbor2: cbor2))
        when Tags::GEOMETRY_POINT       then decode_point(value)
        when Tags::GEOMETRY_LINE        then decode_line(value)
        when Tags::GEOMETRY_POLYGON     then decode_polygon(value)
        when Tags::GEOMETRY_MULTIPOINT  then decode_multipoint(value)
        when Tags::GEOMETRY_MULTILINE   then decode_multiline(value)
        when Tags::GEOMETRY_MULTIPOLYGON then decode_multipolygon(value)
        when Tags::GEOMETRY_COLLECTION then decode_collection(value, cbor2)
        when *Tags::SIZED_KINDS.keys then decode_sized(tag, value, cbor2)
        else
          value
        end
      end

      # The integer tags hold a CBOR integer in the kind's range, and the
      # float tags a CBOR float (of any width) that the kind holds exactly.
      def decode_sized(tag, value, cbor2)
        kind = Tags::SIZED_KINDS.fetch(tag)
        raise ProtocolError, "CBOR tag #{tag} (#{kind}) is only valid in cbor.2" unless cbor2

        if SurrealDB::SizedNumber::FLOAT_KINDS.include?(kind)
          raise ProtocolError, "CBOR tag #{tag} (#{kind}) needs a float, got #{value.inspect}" unless value.is_a?(Float)
          unless SurrealDB::SizedNumber.exact?(kind, value)
            raise ProtocolError, "float #{value} cannot be represented exactly as #{kind}"
          end
        end
        SurrealDB::SizedNumber.new(kind, value)
      rescue TypeError, RangeError => e
        raise ProtocolError, "CBOR tag #{tag} (#{kind}): #{e.message}"
      end

      # The string form ("table:id") is the one StringRecordID sends.
      def decode_record_id(value, cbor2)
        return SurrealDB::StringRecordID.new(value) if value.is_a?(String)

        SurrealDB::RecordID.new(value[0], record_key(resolve(value[1], cbor2: cbor2)))
      end

      # A record id key holds an i64, so the server reads a sized integer key
      # as a plain int, and refuses one past i64 or a float.
      def record_key(key)
        return key unless key.is_a?(SurrealDB::SizedNumber)
        raise ProtocolError, "a record id key cannot be #{key.kind}" if key.float?
        raise ProtocolError, "record id key #{key} does not fit in i64" unless INT64_RANGE.cover?(key.value)

        key.value
      end

      def resolve_uuid(tag, value)
        if tag == Tags::UUID_BINARY && value.bytesize == 16
          SurrealDB::Uuid.new(value)
        else
          SurrealDB::Uuid.parse(value)
        end
      end

      def decode_range(value, cbor2)
        SurrealDB::Range.new(resolve(value[0], cbor2: cbor2), resolve(value[1], cbor2: cbor2))
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

      def decode_collection(geometries, cbor2)
        SurrealDB::GeometryCollection.new(*geometries.map { |g| resolve(g, cbor2: cbor2) })
      end

      private_class_method :resolve_tag, :decode_sized, :decode_record_id, :record_key, :resolve_uuid, :decode_range,
                           :decode_point, :decode_line, :decode_polygon,
                           :decode_multipoint, :decode_multiline,
                           :decode_multipolygon, :decode_collection
    end
  end
end
