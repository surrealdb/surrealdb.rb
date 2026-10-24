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

    it 'handles RecordID with integer id' do
      rid = SurrealDB::RecordID.new('post', 42)
      result = round_trip(rid)
      expect(result.table).to eq('post')
      expect(result.id).to eq(42)
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
end
