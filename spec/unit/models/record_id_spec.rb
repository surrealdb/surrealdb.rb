# frozen_string_literal: true

RSpec.describe SurrealDB::RecordID do
  describe '.new' do
    it 'stores table and id' do
      rid = described_class.new('user', 'john')
      expect(rid.table).to eq('user')
      expect(rid.id).to eq('john')
    end

    it 'accepts integer ids' do
      rid = described_class.new('post', 42)
      expect(rid.id).to eq(42)
    end

    it 'rejects nil table' do
      expect { described_class.new(nil, 'x') }.to raise_error(ArgumentError)
    end

    it 'rejects empty table' do
      expect { described_class.new('', 'x') }.to raise_error(ArgumentError)
    end
  end

  describe '.parse' do
    it 'parses simple string id' do
      rid = described_class.parse('user:john')
      expect(rid.table).to eq('user')
      expect(rid.id).to eq('john')
    end

    it 'parses numeric id as integer' do
      rid = described_class.parse('post:42')
      expect(rid.table).to eq('post')
      expect(rid.id).to eq(42)
    end

    it 'parses angle-bracket escaped ids' do
      rid = described_class.parse("user:\u27E8some-complex-id\u27E9")
      expect(rid.id).to eq('some-complex-id')
    end

    it 'parses backtick and angle-bracket escaped tables' do
      expect(described_class.parse('`my-table`:x')).to eq(described_class.new('my-table', 'x'))
      expect(described_class.parse("\u27E8my table\u27E9:x")).to eq(described_class.new('my table', 'x'))
    end

    it 'keeps ids with letters after digits as strings' do
      expect(described_class.parse('knows:2wl3iofcyqmg6in96bga').id).to eq('2wl3iofcyqmg6in96bga')
    end

    it 'refuses complex ids it cannot parse on the client' do
      expect { described_class.parse("temp:['London', 1]") }.to raise_error(ArgumentError, /StringRecordID/)
    end

    it 'round-trips through #to_s' do
      ['person:alice', "person:\u27E8a-b\u27E9", 'post:42', "\u27E8a:b\u27E9:c", "x:\u27E8123\u27E9"].each do |str|
        expect(described_class.parse(str).to_s).to eq(str)
      end
    end

    it 'rejects strings without colon' do
      expect { described_class.parse('invalid') }.to raise_error(ArgumentError)
    end

    it 'rejects empty table' do
      expect { described_class.parse(':id') }.to raise_error(ArgumentError)
    end
  end

  describe '#to_s' do
    it 'formats simple string ids' do
      expect(described_class.new('user', 'john').to_s).to eq('user:john')
    end

    it 'formats integer ids' do
      expect(described_class.new('post', 42).to_s).to eq('post:42')
    end

    it 'escapes ids with special characters' do
      rid = described_class.new('user', 'some-complex-id')
      expect(rid.to_s).to eq("user:\u27E8some-complex-id\u27E9")
    end

    it 'formats array ids' do
      rid = described_class.new('test', [1, 'two'])
      expect(rid.to_s).to eq('test:[1, "two"]')
    end

    it 'escapes table names that are not identifiers' do
      expect(described_class.new('person:alice', 'x').to_s).to eq("\u27E8person:alice\u27E9:x")
    end

    it 'escapes string ids made only of digits so they do not read as numbers' do
      expect(described_class.new('post', '42').to_s).to eq("post:\u27E842\u27E9")
    end
  end

  describe 'equality' do
    it 'considers same table and id as equal' do
      a = described_class.new('user', 'john')
      b = described_class.new('user', 'john')
      expect(a).to eq(b)
      expect(a.hash).to eq(b.hash)
    end

    it 'considers different ids as not equal' do
      a = described_class.new('user', 'john')
      b = described_class.new('user', 'jane')
      expect(a).not_to eq(b)
    end
  end
end

RSpec.describe SurrealDB::StringRecordID do
  it 'is encoded as CBOR tag 8 carrying the string' do
    tagged = SurrealDB::CBOR::Encoder.prepare(described_class.new('person:alice'))
    expect(tagged.tag).to eq(SurrealDB::CBOR::Tags::RECORD_ID)
    expect(tagged.value).to eq('person:alice')
  end

  it 'rejects empty strings' do
    expect { described_class.new('') }.to raise_error(ArgumentError)
  end
end
