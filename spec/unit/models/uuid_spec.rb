# frozen_string_literal: true

RSpec.describe SurrealDB::Uuid do
  let(:text) { '0190d5ab-7c3e-7d2a-9f1b-123456789abc' }

  it 'parses and formats the canonical form' do
    expect(described_class.parse(text).to_s).to eq(text)
    expect(described_class.parse(text.delete('-')).to_s).to eq(text)
  end

  it 'rejects invalid strings and wrong byte lengths' do
    expect { described_class.parse('not-a-uuid') }.to raise_error(ArgumentError)
    expect { described_class.new('short') }.to raise_error(ArgumentError)
  end

  it 'compares by value' do
    expect(described_class.parse(text)).to eq(described_class.parse(text.upcase))
    expect(described_class.parse(text).hash).to eq(described_class.parse(text.upcase).hash)
    expect(described_class.parse(text)).not_to eq(text)
  end

  it 'generates v4 and v7 uuids with the right version and variant' do
    v4 = described_class.v4.bytes.bytes
    v7 = described_class.v7.bytes.bytes
    expect(v4[6] >> 4).to eq(4)
    expect(v7[6] >> 4).to eq(7)
    expect([v4[8] >> 6, v7[8] >> 6]).to eq([2, 2])
  end

  it 'orders v7 uuids by creation time' do
    a = described_class.v7
    sleep 0.002
    b = described_class.v7
    expect(a.bytes < b.bytes).to be(true)
  end
end

RSpec.describe SurrealDB::FileRef do
  it 'normalises the key to start with a slash' do
    expect(described_class.new('avatars', 'alice.png').key).to eq('/alice.png')
    expect(described_class.new('avatars', '/alice.png').to_s).to eq('f"avatars:/alice.png"')
  end

  it 'compares by value' do
    expect(described_class.new('b', '/k')).to eq(described_class.new('b', 'k'))
  end
end
