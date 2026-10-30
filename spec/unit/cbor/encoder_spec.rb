# frozen_string_literal: true

RSpec.describe SurrealDB::CBOR::Encoder do
  describe '.prepare' do
    it 'converts None to tagged value' do
      result = described_class.prepare(SurrealDB::NONE)
      expect(result).to be_a(CBOR::Tagged)
      expect(result.tag).to eq(SurrealDB::CBOR::Tags::NONE)
    end

    it 'converts Table to tagged value' do
      result = described_class.prepare(SurrealDB::Table.new('users'))
      expect(result).to be_a(CBOR::Tagged)
      expect(result.tag).to eq(SurrealDB::CBOR::Tags::TABLE)
      expect(result.value).to eq('users')
    end

    it 'converts RecordID to tagged value' do
      result = described_class.prepare(SurrealDB::RecordID.new('user', 'john'))
      expect(result).to be_a(CBOR::Tagged)
      expect(result.tag).to eq(SurrealDB::CBOR::Tags::RECORD_ID)
      expect(result.value).to eq(%w[user john])
    end

    it 'converts Duration to tagged value' do
      result = described_class.prepare(SurrealDB::Duration.new(10, 500))
      expect(result).to be_a(CBOR::Tagged)
      expect(result.tag).to eq(SurrealDB::CBOR::Tags::DURATION_COMPACT)
      expect(result.value).to eq([10, 500])
    end

    it 'converts Time to tagged datetime' do
      t = Time.utc(2024, 1, 15, 12, 0, 0)
      result = described_class.prepare(t)
      expect(result).to be_a(CBOR::Tagged)
      expect(result.tag).to eq(SurrealDB::CBOR::Tags::DATETIME_COMPACT)
      expect(result.value[0]).to eq(t.to_i)
    end

    it 'converts BigDecimal to tagged decimal string' do
      result = described_class.prepare(BigDecimal('3.14'))
      expect(result).to be_a(CBOR::Tagged)
      expect(result.tag).to eq(SurrealDB::CBOR::Tags::DECIMAL_STRING)
      expect(result.value).to eq('3.14')
    end

    it 'converts Range with bounds' do
      range = SurrealDB::Range.new(
        SurrealDB::BoundIncluded.new(1),
        SurrealDB::BoundExcluded.new(10)
      )
      result = described_class.prepare(range)
      expect(result.tag).to eq(SurrealDB::CBOR::Tags::RANGE)
    end

    it 'converts GeometryPoint' do
      result = described_class.prepare(SurrealDB::GeometryPoint.new(1.0, 2.0))
      expect(result.tag).to eq(SurrealDB::CBOR::Tags::GEOMETRY_POINT)
      expect(result.value).to eq([1.0, 2.0])
    end

    it 'recursively converts hashes' do
      result = described_class.prepare({ 'table' => SurrealDB::Table.new('x') })
      expect(result['table']).to be_a(CBOR::Tagged)
    end

    it 'recursively converts arrays' do
      result = described_class.prepare([SurrealDB::Table.new('x')])
      expect(result[0]).to be_a(CBOR::Tagged)
    end

    it 'passes through primitives unchanged' do
      expect(described_class.prepare('hello')).to eq('hello')
      expect(described_class.prepare(42)).to eq(42)
      expect(described_class.prepare(true)).to be(true)
      expect(described_class.prepare(nil)).to be_nil
    end

    it 'accepts the whole signed 64-bit range' do
      expect(described_class.prepare((2**63) - 1)).to eq((2**63) - 1)
      expect(described_class.prepare(-(2**63))).to eq(-(2**63))
    end

    it 'refuses an integer outside 64 bits, which the server wraps (3.x) or refuses (4.0)' do
      [2**63, (2**64) - 1, 2**64, -(2**63) - 1].each do |int|
        expect { described_class.prepare(int) }.to raise_error(RangeError, /does not fit in 64 bits/)
      end
      expect { described_class.prepare({ 'a' => [2**63] }) }.to raise_error(RangeError)
    end

    it 'writes Symbol keys as the String keys they become' do
      expect(described_class.prepare({ a: SurrealDB::NONE })).to eq({ 'a' => CBOR::Tagged.new(6, nil) })
    end

    it 'refuses a Symbol and a String key that name the same field' do
      expect { described_class.prepare({ :a => 1, 'a' => 2 }) }.to raise_error(ArgumentError, /duplicate key "a"/)
      expect { described_class.prepare([{ 'b' => { :c => 1, 'c' => 2 } }]) }.to raise_error(ArgumentError, /"c"/)
    end
  end

  # SurrealDB 4.0 refuses the text forms of datetimes (tag 0), uuids (tag 9)
  # and durations (tag 13); they are only ever read.
  describe 'tags written' do
    def tags_in(value)
      raw = CBOR.decode(described_class.encode(value))
      collect_tags(raw)
    end

    def collect_tags(node)
      case node
      when CBOR::Tagged then [node.tag] + collect_tags(node.value)
      when Array then node.flat_map { |v| collect_tags(v) }
      when Hash then node.values.flat_map { |v| collect_tags(v) }
      else []
      end
    end

    it 'writes a datetime as tag 12, a uuid as tag 37 and a duration as tag 14' do
      expect(tags_in(Time.at(1_700_000_000, 5, :nsec))).to eq([12])
      expect(tags_in(SurrealDB::Uuid.v4)).to eq([37])
      expect(tags_in(SurrealDB::Duration.parse('1h30m'))).to eq([14])
    end

    it 'never writes tag 0, 9 or 13, however deeply a value is nested' do
      value = { 'at' => [Time.now, { 'id' => SurrealDB::Uuid.v7 }],
                'ids' => Set.new([SurrealDB::Uuid.v4]),
                'range' => SurrealDB::Range.new(SurrealDB::BoundIncluded.new(Time.now),
                                                SurrealDB::BoundExcluded.new(SurrealDB::Duration.parse('1s'))),
                'record' => SurrealDB::RecordID.new('t', [Time.now, SurrealDB::Uuid.v4]) }
      tags = tags_in(value)
      expect(tags).to include(12, 14, 37)
      expect(tags & [0, 9, 13]).to be_empty
    end
  end

  describe '.encode' do
    it 'returns a binary string' do
      result = described_class.encode('hello')
      expect(result).to be_a(String)
      expect(result.encoding).to eq(Encoding::BINARY)
    end
  end

  describe 'sized numbers' do
    def hex(value, cbor2:)
      described_class.encode(value, cbor2: cbor2).unpack1('H*')
    end

    it 'tags each kind over cbor.2' do
      expect(hex(SurrealDB::SizedNumber.u8(5), cbor2: true)).to eq('d8b505')
      expect(hex(SurrealDB::SizedNumber.i8(-128), cbor2: true)).to eq('d8b4387f')
      expect(hex(SurrealDB::SizedNumber.u64((2**64) - 1), cbor2: true)).to eq('d8ba1bffffffffffffffff')
      expect(hex(SurrealDB::SizedNumber.f16(1.5), cbor2: true)).to eq('d8bbf93e00')
      expect(hex(SurrealDB::SizedNumber.f32(0.1), cbor2: true)).to eq('d8bcfa3dcccccd')
    end

    it 'keeps tags inside arrays, objects and record ids' do
      value = { 'a' => [SurrealDB::SizedNumber.i8(1)],
                'r' => SurrealDB::RecordID.new('t', [SurrealDB::SizedNumber.u8(5)]) }
      expect(hex(value, cbor2: true)).to eq('a2616181d8b4016172c882617481d8b505')
    end

    it 'widens over plain cbor, as the server does' do
      expect(hex(SurrealDB::SizedNumber.u8(5), cbor2: false)).to eq('05')
      expect(hex(SurrealDB::SizedNumber.f32(1.5), cbor2: false)).to eq('f93e00')
      expect(hex(SurrealDB::SizedNumber.u64(2**63), cbor2: false)).to eq(
        "ca73#{'9223372036854775808'.unpack1('H*')}"
      )
    end

    it 'leaves a plain Integer and Float untagged over cbor.2' do
      expect(hex([5, 1.5], cbor2: true)).to eq('8205f93e00')
    end
  end
end
