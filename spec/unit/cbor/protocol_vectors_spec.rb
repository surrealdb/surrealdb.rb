# frozen_string_literal: true

# The CBOR test vectors of surrealdb-protocol (spec/vectors/*.yaml there),
# run through the codec as the protocol's spec/README.md lays out:
#
#   canonical  decode(cbor) == value, and decode(encode(value)) == value
#   decode     decode(cbor) == value
#   reject     decode(cbor) raises
#
# Plain cbor runs every cbor.yaml vector that does not leave it out; cbor.2
# runs every cbor.yaml vector that does not leave it out, and cbor2.yaml.
# The vectors in SurrealDBProtocol::KNOWN_VECTOR_GAPS are pending. The
# encoder is exercised too, by each canonical vector's round trip.
RSpec.describe SurrealDB::CBOR::Decoder, '.decode' do
  def same?(left, right)
    SurrealDB::Conformance::TypedJson.same?(left, right)
  end

  def bytes(hex)
    raise ArgumentError, "expected hex, got #{hex.inspect}" unless hex.is_a?(String)

    [hex].pack('H*')
  end

  def check(vector, cbor2)
    input = bytes(vector['cbor'])
    if vector['kind'] == 'reject'
      expect { described_class.decode(input, cbor2: cbor2) }.to raise_error(StandardError)
      return
    end

    expected = SurrealDB::Conformance::TypedJson.from_json(vector['value'])
    decoded = described_class.decode(input, cbor2: cbor2)
    expect(same?(decoded, expected)).to be(true), "decoded #{decoded.inspect}, expected #{expected.inspect}"
    check_round_trip(expected, cbor2) if vector['kind'] == 'canonical'
  end

  def check_round_trip(value, cbor2)
    encoded = SurrealDB::CBOR::Encoder.encode(value, cbor2: cbor2)
    round_trip = described_class.decode(encoded, cbor2: cbor2)
    expect(same?(round_trip, value)).to be(true),
                                        "encoded #{encoded.unpack1('H*')}, which decodes to #{round_trip.inspect}"
  end

  if SurrealDBProtocol.available?
    it 'lists only gaps that are vectors' do
      names = %w[cbor.yaml cbor2.yaml].flat_map { |file| SurrealDBProtocol.vectors(file).map { |v| v['name'] } }
      expect(SurrealDBProtocol::KNOWN_VECTOR_GAPS.keys - names).to be_empty
    end
  else
    it 'needs surrealdb-protocol: run conformance/fetch-protocol' do
      raise "surrealdb-protocol is not in #{SurrealDBProtocol::DIR}" if SurrealDBProtocol.required?

      skip "surrealdb-protocol #{SurrealDBProtocol::VERSION} is not checked out; run conformance/fetch-protocol"
    end
  end

  {
    'cbor' => [%w[cbor.yaml cbor]],
    'cbor.2' => [%w[cbor.yaml cbor.2], %w[cbor2.yaml cbor.2]]
  }.each do |dialect, files|
    context "with #{dialect}" do
      files.each do |file, format|
        SurrealDBProtocol.vectors(file).each do |vector|
          next if vector['formats'] && !vector['formats'].include?(format)

          it "#{vector['kind']}: #{vector['name']} (#{file})", cbor2: dialect == 'cbor.2', vector: vector do |example|
            meta = example.metadata
            gap = SurrealDBProtocol::KNOWN_VECTOR_GAPS[meta[:vector]['name']]
            pending(gap) if gap

            check(meta[:vector], meta[:cbor2])
          end
        end
      end
    end
  end
end
