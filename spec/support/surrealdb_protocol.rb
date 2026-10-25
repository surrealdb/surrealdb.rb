# frozen_string_literal: true

require 'yaml'
require_relative '../../conformance/typed_json'

# The surrealdb-protocol repository (test vectors and the conformance suite),
# checked out at the tag in conformance/surrealdb-protocol.version by
# `rake conformance:fetch`, or wherever SURREALDB_PROTOCOL_DIR points.
module SurrealDBProtocol
  ROOT = File.expand_path('../..', __dir__)
  VERSION = File.read(File.join(ROOT, 'conformance', 'surrealdb-protocol.version')).strip
  DIR = ENV.fetch('SURREALDB_PROTOCOL_DIR') { File.join(ROOT, 'tmp', 'surrealdb-protocol') }

  # Vectors the codec does not yet do what they ask (by name, with why).
  # Each of these is
  # pending, so one that starts to pass fails the run until it comes off the
  # list. None of them is about the sized numbers.
  KNOWN_VECTOR_GAPS = {
    'the decoder reads only the long form of a duration ([] and [secs] are fixed on main), and secs past i64' =>
      %w[duration-zero duration-whole-seconds duration-u64-seconds],
    'the decoder expects lines and polygons as raw coordinates, not the tagged points the server sends' =>
      %w[geometry-linestring geometry-polygon geometry-polygon-with-hole geometry-multipoint
         geometry-multilinestring geometry-polygon-unclosed-ring geometry-multipolygon geometry-collection],
    'a string-form record id decodes to an unparsed StringRecordID' =>
      %w[record-id-string-form record-id-string-form-int-key record-id-string-form-array-key
         record-id-string-form-object-key record-id-string-form-uuid-key record-id-string-form-escapes
         record-id-string-form-escaped-table record-id-string-form-backtick-table
         record-id-string-form-digits-past-i64 reject-record-id-string-form-unknown-escape
         reject-record-id-string-form-surrogate-escape],
    'Ruby\'s CBOR library keeps the last of two equal map keys, and reads integers past i64' =>
      %w[reject-object-duplicate-key reject-int-beyond-i64 reject-untagged-integer-past-i64],
    'the decoder still reads the text tags 0, 9 and 13 that 4.0 refuses' =>
      %w[reject-datetime-string-tag-0 reject-uuid-string-tag-9 reject-duration-string-tag-13
         reject-record-id-uuid-string-key reject-duration-string-beyond-u64
         reject-duration-string-nanoseconds-carry-beyond-u64],
    'the decoder does not check the shape or range of what a tag holds' =>
      %w[reject-none-with-payload reject-datetime-after-chrono-max reject-datetime-before-chrono-min
         reject-datetime-impossible-date reject-datetime-negative-nanoseconds reject-datetime-seconds-beyond-i64
         reject-decimal-beyond-96-bits reject-decimal-mantissa-beyond-96-bits reject-decimal-scale-beyond-28
         reject-decimal-surrounding-whitespace reject-decimal-trailing-whitespace
         reject-duration-negative-nanoseconds reject-duration-three-elements reject-file-non-string-key
         reject-file-one-element reject-indefinite-text-split-code-point reject-object-integer-key
         reject-point-one-coordinate reject-range-one-bound reject-range-untagged-bound
         reject-record-id-bool-key reject-record-id-decimal-key reject-record-id-float-key
         reject-record-id-one-element reject-record-id-range-bool-bound reject-record-id-three-elements],
    'the decoder passes unknown and unsupported tags through instead of refusing them' =>
      %w[reject-shaped-block-malformed reject-tag-binary-decimal reject-tag-future reject-unknown-tag]
  }.flat_map { |reason, names| names.map { |name| [name, reason] } }.to_h.freeze

  module_function

  def available?
    File.exist?(vectors_path('cbor.yaml'))
  end

  # CI sets this, so a missing checkout fails the run instead of skipping.
  def required?
    ENV['SURREALDB_PROTOCOL_REQUIRED'] == '1'
  end

  def vectors_path(name)
    File.join(DIR, 'spec', 'vectors', name)
  end

  # @return [Array<Hash>] the file's vectors, or none when it is not checked out
  def vectors(name)
    return [] unless available?

    YAML.safe_load_file(vectors_path(name)).fetch('vectors')
  end
end
