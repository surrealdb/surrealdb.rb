# frozen_string_literal: true

RSpec.describe SurrealDB::CBOR::Decoder do
  def round_trip(obj)
    encoded = SurrealDB::CBOR::Encoder.encode(obj)
    described_class.decode(encoded)
  end

  describe 'round-trip encoding/decoding' do
    it 'handles None' do
      result = round_trip(SurrealDB::NONE)
      expect(result).to eq(SurrealDB::NONE)
    end

    it 'handles Table' do
      result = round_trip(SurrealDB::Table.new('users'))
      expect(result).to eq(SurrealDB::Table.new('users'))
    end

    it 'handles RecordID with string id' do
      rid = SurrealDB::RecordID.new('user', 'john')
      result = round_trip(rid)
      expect(result).to be_a(SurrealDB::RecordID)
      expect(result.table).to eq('user')
      expect(result.id).to eq('john')
    end

    it 'handles StringRecordID, the string form of the record id tag' do
      expect(round_trip(SurrealDB::StringRecordID.new('person:alice'))).to eq(SurrealDB::StringRecordID.new('person:alice'))
    end

    it 'handles RecordID with integer id' do
      rid = SurrealDB::RecordID.new('post', 42)
      result = round_trip(rid)
      expect(result.table).to eq('post')
      expect(result.id).to eq(42)
    end

    it 'handles Uuid as CBOR tag 37 with 16 raw bytes' do
      uuid = SurrealDB::Uuid.parse('0190d5ab-7c3e-7d2a-9f1b-123456789abc')
      raw = CBOR.decode(SurrealDB::CBOR::Encoder.encode(uuid))
      expect(raw.tag).to eq(37)
      expect(raw.value.encoding).to eq(Encoding::BINARY)
      expect(raw.value.bytesize).to eq(16)
      expect(round_trip(uuid)).to eq(uuid)
    end

    it 'handles RecordID with a Uuid key' do
      rid = SurrealDB::RecordID.new('user', SurrealDB::Uuid.v7)
      expect(round_trip(rid)).to eq(rid)
    end

    it 'decodes tag 9 (string uuid) to Uuid' do
      text = '0190d5ab-7c3e-7d2a-9f1b-123456789abc'
      expect(described_class.decode(CBOR.encode(CBOR::Tagged.new(9, text)))).to eq(SurrealDB::Uuid.parse(text))
    end

    it 'decodes tag 0 (RFC 3339 datetime) to Time with nanoseconds' do
      time = described_class.decode(CBOR.encode(CBOR::Tagged.new(0, '2020-01-02T03:04:05.123456789Z')))
      expect(time).to eq(Time.utc(2020, 1, 2, 3, 4, 5r + Rational(123_456_789, 1_000_000_000)))
      expect(time.nsec).to eq(123_456_789)
    end

    it 'handles FileRef as CBOR tag 55' do
      file = SurrealDB::FileRef.new('bucket', '/a/b.txt')
      raw = CBOR.decode(SurrealDB::CBOR::Encoder.encode(file))
      expect([raw.tag, raw.value]).to eq([55, ['bucket', '/a/b.txt']])
      expect(round_trip(file)).to eq(file)
    end

    it 'handles Set as CBOR tag 56' do
      set = Set[1, 'two', SurrealDB::RecordID.new('t', 1)]
      raw = CBOR.decode(SurrealDB::CBOR::Encoder.encode(set))
      expect(raw.tag).to eq(56)
      expect(round_trip(set)).to eq(set)
    end

    it 'handles Duration' do
      d = SurrealDB::Duration.new(3600, 500_000_000)
      result = round_trip(d)
      expect(result).to eq(d)
    end

    it 'decodes a compact Duration with no fields as zero' do
      encoded = CBOR::Tagged.new(SurrealDB::CBOR::Tags::DURATION_COMPACT, []).to_cbor
      expect(described_class.decode(encoded)).to eq(SurrealDB::Duration.new(0, 0))
    end

    it 'decodes a compact Duration with seconds only' do
      encoded = CBOR::Tagged.new(SurrealDB::CBOR::Tags::DURATION_COMPACT, [5]).to_cbor
      expect(described_class.decode(encoded)).to eq(SurrealDB::Duration.new(5, 0))
    end

    [[-1], [0, -1], [1, 2, 3], [1.5]].each do |fields|
      it "refuses a compact Duration of #{fields.inspect}" do
        encoded = CBOR::Tagged.new(SurrealDB::CBOR::Tags::DURATION_COMPACT, fields).to_cbor
        expect { described_class.decode(encoded) }.to raise_error(SurrealDB::ProtocolError, /unsigned integers/)
      end
    end

    it 'handles Time (datetime)' do
      t = Time.utc(2024, 6, 15, 12, 30, 45)
      result = round_trip(t)
      expect(result).to be_a(Time)
      expect(result.to_i).to eq(t.to_i)
    end

    it 'handles BigDecimal' do
      d = BigDecimal('123.456')
      result = round_trip(d)
      expect(result).to be_a(BigDecimal)
      expect(result).to eq(d)
    end

    it 'handles Range with included bounds' do
      range = SurrealDB::Range.new(
        SurrealDB::BoundIncluded.new(1),
        SurrealDB::BoundIncluded.new(10)
      )
      result = round_trip(range)
      expect(result).to be_a(SurrealDB::Range)
      expect(result.begin_bound).to be_a(SurrealDB::BoundIncluded)
      expect(result.begin_bound.value).to eq(1)
      expect(result.end_bound.value).to eq(10)
    end

    it 'handles GeometryPoint' do
      p = SurrealDB::GeometryPoint.new(-122.4194, 37.7749)
      result = round_trip(p)
      expect(result).to eq(p)
    end

    it 'handles GeometryLine' do
      line = SurrealDB::GeometryLine.new(
        SurrealDB::GeometryPoint.new(0.0, 0.0),
        SurrealDB::GeometryPoint.new(1.0, 1.0)
      )
      result = round_trip(line)
      expect(result).to eq(line)
    end

    it 'handles GeometryPolygon' do
      exterior = SurrealDB::GeometryLine.new(
        SurrealDB::GeometryPoint.new(0.0, 0.0),
        SurrealDB::GeometryPoint.new(1.0, 0.0),
        SurrealDB::GeometryPoint.new(1.0, 1.0),
        SurrealDB::GeometryPoint.new(0.0, 0.0)
      )
      polygon = SurrealDB::GeometryPolygon.new(exterior)
      result = round_trip(polygon)
      expect(result).to eq(polygon)
    end

    it 'handles nested structures' do
      data = {
        'name' => 'John',
        'id' => SurrealDB::RecordID.new('user', 'john'),
        'tags' => [SurrealDB::Table.new('tags')],
        'none_val' => SurrealDB::NONE
      }
      result = round_trip(data)
      expect(result['name']).to eq('John')
      expect(result['id']).to be_a(SurrealDB::RecordID)
      expect(result['tags'][0]).to be_a(SurrealDB::Table)
      expect(result['none_val']).to eq(SurrealDB::NONE)
    end

    it 'handles primitives' do
      expect(round_trip('hello')).to eq('hello')
      expect(round_trip(42)).to eq(42)
      expect(round_trip(3.14)).to be_within(0.001).of(3.14)
      expect(round_trip(true)).to be(true)
      expect(round_trip(false)).to be(false)
      expect(round_trip(nil)).to be_nil
    end

    it 'handles empty structures' do
      expect(round_trip({})).to eq({})
      expect(round_trip([])).to eq([])
    end
  end

  describe 'sized numbers' do
    def decode(hex, cbor2:)
      described_class.decode([hex].pack('H*'), cbor2: cbor2)
    end

    it 'reads tags 180 to 188 over cbor.2' do
      expect(decode('d8b505', cbor2: true)).to eq(SurrealDB::SizedNumber.u8(5))
      expect(decode('d8ba1bffffffffffffffff', cbor2: true)).to eq(SurrealDB::SizedNumber.u64((2**64) - 1))
      expect(decode('d8bbf93e00', cbor2: true)).to eq(SurrealDB::SizedNumber.f16(1.5))
      expect(decode('d8bbfb3ff8000000000000', cbor2: true)).to eq(SurrealDB::SizedNumber.f16(1.5))
    end

    it 'refuses them over plain cbor' do
      expect { decode('d8b505', cbor2: false) }.to raise_error(SurrealDB::ProtocolError, /only valid in cbor.2/)
    end

    it 'refuses a value outside the kind, or of the wrong type' do
      expect { decode('d8b41880', cbor2: true) }.to raise_error(SurrealDB::ProtocolError, /outside the i8 range/)
      expect { decode('d8b5f93c00', cbor2: true) }.to raise_error(SurrealDB::ProtocolError, /needs an Integer/)
      expect { decode('d8bb01', cbor2: true) }.to raise_error(SurrealDB::ProtocolError, /needs a float/)
      expect { decode('d8bbfb3fb999999999999a', cbor2: true) }.to raise_error(SurrealDB::ProtocolError, /exactly/)
    end

    it 'reads a sized integer record id key as a plain int' do
      expect(decode('c8826174d8b505', cbor2: true)).to eq(SurrealDB::RecordID.new('t', 5))
      expect { decode('c8826174d8ba1bffffffffffffffff', cbor2: true) }.to raise_error(SurrealDB::ProtocolError)
      expect { decode('c8826174d8bbf93e00', cbor2: true) }.to raise_error(SurrealDB::ProtocolError)
    end
  end
end
