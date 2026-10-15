# frozen_string_literal: true

module SurrealDB
  module CBOR
    # SurrealDB custom CBOR tag numbers.
    # These match the tag definitions in the Go and Python SDKs.
    module Tags
      DATETIME_STRING   = 0 # RFC 3339 text; decoded only
      NONE              = 6
      TABLE             = 7
      RECORD_ID         = 8
      UUID_STRING       = 9
      DECIMAL_STRING    = 10
      DATETIME_COMPACT  = 12
      DURATION_STRING   = 13
      DURATION_COMPACT  = 14
      FUTURE            = 15
      UUID_BINARY       = 37
      RANGE             = 49
      BOUND_INCLUDED    = 50
      BOUND_EXCLUDED    = 51
      FILE              = 55
      SET               = 56
      GEOMETRY_POINT    = 88
      GEOMETRY_LINE     = 89
      GEOMETRY_POLYGON  = 90
      GEOMETRY_MULTIPOINT    = 91
      GEOMETRY_MULTILINE     = 92
      GEOMETRY_MULTIPOLYGON  = 93
      GEOMETRY_COLLECTION    = 94
    end
  end
end
