# frozen_string_literal: true

RSpec.describe SurrealDB::SizedNumber do
  describe 'integer kinds' do
    it 'holds a value within the kind' do
      expect(described_class.u8(255).value).to eq(255)
      expect(described_class.i8(-128).value).to eq(-128)
      expect(described_class.u64((2**64) - 1).value).to eq((2**64) - 1)
    end

    it 'refuses a value outside the kind' do
      expect { described_class.u8(256) }.to raise_error(RangeError, /outside the u8 range/)
      expect { described_class.i16(-32_769) }.to raise_error(RangeError)
      expect { described_class.u64(-1) }.to raise_error(RangeError)
    end

    it 'refuses a non-integer' do
      expect { described_class.i32(1.5) }.to raise_error(TypeError, /needs an Integer/)
    end
  end

  describe 'float kinds' do
    it 'rounds to the nearest f32' do
      expect(described_class.f32(0.1).value).to eq(0.10000000149011612)
    end

    it 'rounds to the nearest f16, ties to even' do
      expect(described_class.f16(0.1).value).to eq(0.0999755859375)
      expect(described_class.f16(1.00048828125).value).to eq(1.0)
      expect(described_class.f16(1.00146484375).value).to eq(1.001953125)
    end

    it 'rounds past the f16 range to infinity' do
      expect(described_class.f16(65_519).value).to eq(65_504.0)
      expect(described_class.f16(65_520).value).to eq(Float::INFINITY)
      expect(described_class.f16(-1e9).value).to eq(-Float::INFINITY)
    end

    it 'keeps f16 subnormals and the sign of a value that rounds to zero' do
      expect(described_class.f16(5.960464477539063e-8).value).to eq(5.960464477539063e-8)
      negative_zero = described_class.f16(-1e-9).value
      expect(negative_zero).to eq(0.0)
      expect(1.0 / negative_zero).to be_negative
    end

    it 'keeps NaN and the infinities' do
      expect(described_class.f16(Float::NAN).value).to be_nan
      expect(described_class.f32(-Float::INFINITY).value).to eq(-Float::INFINITY)
    end
  end

  it 'refuses an unknown kind' do
    expect { described_class.new(:i128, 1) }.to raise_error(ArgumentError, /unknown number kind/)
  end

  describe 'equality' do
    it 'compares kind and value' do
      five = described_class.u8(5)
      expect(five).to eq(described_class.new(:u8, 5))
      expect(five).not_to eq(described_class.u16(5))
      expect(five.hash).to eq(described_class.new(:u8, 5).hash)
    end

    it 'is never equal to a plain number' do
      expect(described_class.u8(5)).not_to eq(5)
    end

    it 'treats NaN as equal to NaN' do
      expect(described_class.f32(Float::NAN)).to eq(described_class.new(:f32, -Float::NAN))
    end
  end

  it 'prints as a SurrealQL literal' do
    expect(described_class.u8(5).to_s).to eq('5u8')
    expect(described_class.f32(1.5).to_s).to eq('1.5f32')
    expect(described_class.f16(Float::NAN).to_s).to eq('<f16>NaN')
  end
end
