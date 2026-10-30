# frozen_string_literal: true

require 'bigdecimal'
require 'time'
require 'surrealdb'

module SurrealDB
  module Conformance
    # Typed JSON, the value notation of the surrealdb-protocol conformance
    # suite and test vectors (spec/README.md there), to and from the SDK's
    # Ruby values.
    module TypedJson
      SIZED = SurrealDB::SizedNumber::KINDS.to_h { |kind| ["$#{kind}", kind] }.freeze

      TYPED = (%w[
        $none $int $float $decimal $string $bytes $uuid $datetime $duration $array $object
        $set $table $record $range $file $geometry $regex
      ] + SIZED.keys).to_set.freeze

      SAFE_INTEGER = (-(2**53))..(2**53)

      SPECIAL_FLOATS = {
        'NaN' => Float::NAN, 'Infinity' => Float::INFINITY, '-Infinity' => -Float::INFINITY, '-0' => -0.0
      }.freeze

      GEOMETRY_TYPES = {
        'Point' => :point, 'LineString' => :line, 'Polygon' => :polygon, 'MultiPoint' => :multipoint,
        'MultiLineString' => :multiline, 'MultiPolygon' => :multipolygon
      }.freeze

      # Raised for a value the SDK has no Ruby type for.
      class Unrepresentable < StandardError; end

      module_function

      # @param json [Object] parsed typed JSON
      # @return [Object] the SDK's Ruby value
      def from_json(json)
        case json
        when Array then json.map { |v| from_json(v) }
        when Hash
          key = typed_key(json)
          key ? from_typed(key, json[key]) : json.to_h { |k, v| [k.to_s, from_json(v)] }
        else json
        end
      end

      # @param value [Object] a Ruby value the SDK produced
      # @return [Object] typed JSON, ready for JSON.generate
      def to_json(value) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
        case value
        when nil, true, false then value
        when SurrealDB::None then { '$none' => nil }
        when Integer then SAFE_INTEGER.cover?(value) ? value : { '$int' => value.to_s }
        when Float then { '$float' => float_json(value) }
        when SurrealDB::SizedNumber then { "$#{value.kind}" => sized_json(value) }
        when BigDecimal then { '$decimal' => decimal_json(value) }
        when String then value.encoding == Encoding::BINARY ? { '$bytes' => value.unpack1('H*') } : value
        when SurrealDB::Uuid then { '$uuid' => value.to_s }
        when Time then { '$datetime' => datetime_json(value) }
        when SurrealDB::Duration then { '$duration' => [integer_json(value.secs), value.nanos] }
        when Array then value.map { |v| to_json(v) }
        when ::Set then { '$set' => value.map { |v| to_json(v) } }
        when Hash then object_json(value)
        when SurrealDB::Table then { '$table' => value.name }
        when SurrealDB::RecordID then { '$record' => { 'table' => value.table, 'key' => to_json(value.id) } }
        when SurrealDB::Range then { '$range' => { 'start' => bound_json(value.begin_bound),
                                                   'end' => bound_json(value.end_bound) } }
        when SurrealDB::FileRef then { '$file' => { 'bucket' => value.bucket, 'key' => value.key } }
        when *GEOMETRIES then { '$geometry' => geometry_json(value) }
        else raise Unrepresentable, "cannot express #{value.inspect} as typed JSON"
        end
      end

      # Equality as the vectors define it: datetimes and durations to the
      # nanosecond, sets and objects regardless of order, NaN equal to NaN,
      # -0.0 unlike 0.0, an Integer never equal to a Float, and bytes never
      # equal to text.
      def same?(left, right) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
        case left
        when Float then right.is_a?(Float) && same_float?(left, right)
        when Integer then right.is_a?(Integer) && left == right
        when String
          right.is_a?(String) && (left.encoding == Encoding::BINARY) == (right.encoding == Encoding::BINARY) &&
            left.b == right.b
        when Array
          right.is_a?(Array) && left.length == right.length && left.zip(right).all? { |l, r| same?(l, r) }
        when Hash
          right.is_a?(Hash) && left.keys.sort == right.keys.sort && left.all? { |k, v| same?(v, right[k]) }
        when ::Set
          right.is_a?(::Set) && left.size == right.size && left.all? { |l| right.any? { |r| same?(l, r) } }
        when Time then right.is_a?(Time) && left.to_r == right.to_r
        when SurrealDB::SizedNumber
          right.is_a?(SurrealDB::SizedNumber) && left.kind == right.kind && same?(left.value, right.value)
        when SurrealDB::RecordID
          right.is_a?(SurrealDB::RecordID) && left.table == right.table && same?(left.id, right.id)
        else left.instance_of?(right.class) && left == right
        end
      end

      GEOMETRIES = [
        SurrealDB::GeometryPoint, SurrealDB::GeometryLine, SurrealDB::GeometryPolygon,
        SurrealDB::GeometryMultiPoint, SurrealDB::GeometryMultiLine, SurrealDB::GeometryMultiPolygon,
        SurrealDB::GeometryCollection
      ].freeze

      def typed_key(hash)
        return unless hash.size == 1

        key = hash.keys.first.to_s
        key if TYPED.include?(key)
      end

      def from_typed(key, arg) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
        return SurrealDB::SizedNumber.new(SIZED[key], sized_value(SIZED[key], arg)) if SIZED.key?(key)

        case key
        when '$none' then SurrealDB::NONE
        when '$int' then Integer(arg)
        when '$float' then float_value(arg)
        when '$decimal' then BigDecimal(arg)
        when '$string' then arg.to_s
        when '$bytes' then [arg].pack('H*')
        when '$uuid' then SurrealDB::Uuid.parse(arg)
        when '$datetime' then Time.iso8601(arg).utc
        when '$duration' then SurrealDB::Duration.new(Integer(arg[0]), Integer(arg[1] || 0))
        when '$array' then arg.map { |v| from_json(v) }
        when '$object' then arg.to_h { |k, v| [k.to_s, from_json(v)] }
        when '$set' then ::Set.new(arg.map { |v| from_json(v) })
        when '$table' then SurrealDB::Table.new(arg)
        when '$record' then SurrealDB::RecordID.new(arg['table'], from_json(arg['key']))
        when '$range' then SurrealDB::Range.new(bound_value(arg['start']), bound_value(arg['end']))
        when '$file' then SurrealDB::FileRef.new(arg['bucket'], arg['key'])
        when '$geometry' then geometry_value(arg)
        else raise Unrepresentable, "the SDK has no value for #{key}"
        end
      end

      def sized_value(kind, arg)
        return float_value(arg) if SurrealDB::SizedNumber::FLOAT_KINDS.include?(kind)

        Integer(arg)
      end

      def float_value(arg)
        SPECIAL_FLOATS.fetch(arg) { Float(arg) }
      end

      def bound_value(bound)
        return nil if bound.nil?
        return SurrealDB::BoundIncluded.new(from_json(bound['included'])) if bound.key?('included')

        SurrealDB::BoundExcluded.new(from_json(bound['excluded']))
      end

      def geometry_value(geo) # rubocop:disable Metrics/CyclomaticComplexity
        coords = geo['coordinates']
        case GEOMETRY_TYPES[geo['type']]
        when :point then point_value(coords)
        when :line then line_value(coords)
        when :polygon then polygon_value(coords)
        when :multipoint then SurrealDB::GeometryMultiPoint.new(*coords.map { |c| point_value(c) })
        when :multiline then SurrealDB::GeometryMultiLine.new(*coords.map { |c| line_value(c) })
        when :multipolygon then SurrealDB::GeometryMultiPolygon.new(*coords.map { |c| polygon_value(c) })
        else SurrealDB::GeometryCollection.new(*geo['geometries'].map { |g| geometry_value(g) })
        end
      end

      def coordinate(value)
        value.is_a?(Hash) ? float_value(value['$float']) : Float(value)
      end

      def point_value(coords)
        SurrealDB::GeometryPoint.new(coordinate(coords[0]), coordinate(coords[1]))
      end

      def line_value(coords)
        SurrealDB::GeometryLine.new(*coords.map { |c| point_value(c) })
      end

      def polygon_value(rings)
        lines = rings.map { |r| line_value(r) }
        SurrealDB::GeometryPolygon.new(lines.first, *lines.drop(1))
      end

      def integer_json(int)
        SAFE_INTEGER.cover?(int) ? int : int.to_s
      end

      def float_json(float)
        return 'NaN' if float.nan?
        return float.positive? ? 'Infinity' : '-Infinity' if float.infinite?
        return '-0' if float.zero? && (1.0 / float).negative?

        float
      end

      def sized_json(number)
        number.float? ? float_json(number.value) : integer_json(number.value)
      end

      # Normalised: no exponent and no trailing fractional zeros.
      def decimal_json(decimal)
        decimal.to_s('F').sub(/(\.\d*?)0+\z/, '\1').delete_suffix('.')
      end

      def datetime_json(time)
        utc = time.getutc
        frac = utc.nsec.zero? ? '' : format('.%09d', utc.nsec)
        "#{utc.strftime('%Y-%m-%dT%H:%M:%S')}#{frac}Z"
      end

      def object_json(hash)
        out = hash.to_h { |k, v| [k.to_s, to_json(v)] }
        typed_key(out) ? { '$object' => out } : out
      end

      def bound_json(bound)
        case bound
        when SurrealDB::BoundIncluded then { 'included' => to_json(bound.value) }
        when SurrealDB::BoundExcluded then { 'excluded' => to_json(bound.value) }
        end
      end

      def geometry_json(geo) # rubocop:disable Metrics/CyclomaticComplexity
        case geo
        when SurrealDB::GeometryPoint then { 'type' => 'Point', 'coordinates' => coords_json(geo.coordinates) }
        when SurrealDB::GeometryLine then { 'type' => 'LineString', 'coordinates' => coords_json(geo.coordinates) }
        when SurrealDB::GeometryPolygon then { 'type' => 'Polygon', 'coordinates' => coords_json(polygon_coords(geo)) }
        when SurrealDB::GeometryMultiPoint
          { 'type' => 'MultiPoint', 'coordinates' => coords_json(geo.points.map(&:coordinates)) }
        when SurrealDB::GeometryMultiLine
          { 'type' => 'MultiLineString', 'coordinates' => coords_json(geo.lines.map(&:coordinates)) }
        when SurrealDB::GeometryMultiPolygon
          { 'type' => 'MultiPolygon', 'coordinates' => coords_json(geo.polygons.map { |p| polygon_coords(p) }) }
        else { 'type' => 'GeometryCollection', 'geometries' => geo.geometries.map { |g| geometry_json(g) } }
        end
      end

      def polygon_coords(polygon)
        [polygon.exterior, *polygon.interiors].map(&:coordinates)
      end

      # GeoJSON coordinates are plain numbers, except the floats JSON cannot hold.
      def coords_json(coords)
        return coords.map { |c| coords_json(c) } if coords.is_a?(Array)

        float = Float(coords)
        float.finite? && !(float.zero? && (1.0 / float).negative?) ? float : { '$float' => float_json(float) }
      end

      def same_float?(left, right)
        return right.nan? if left.nan?

        left == right && (1.0 / left).negative? == (1.0 / right).negative?
      end

      private_class_method :typed_key, :from_typed, :sized_value, :float_value, :bound_value,
                           :geometry_value, :coordinate, :point_value, :line_value, :polygon_value,
                           :integer_json, :float_json, :sized_json, :decimal_json, :datetime_json,
                           :object_json, :bound_json, :geometry_json, :polygon_coords, :coords_json,
                           :same_float?
    end
  end
end
