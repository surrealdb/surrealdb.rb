# frozen_string_literal: true

RSpec.describe SurrealDB::ServerVersion do
  describe '.parse' do
    it 'reads the version number from what the server reports' do
      expect(described_class.parse('surrealdb-3.3.4')).to eq(Gem::Version.new('3.3.4'))
      expect(described_class.parse('surrealdb-3.4.0-nightly+20261014.4f7fa16')).to eq(Gem::Version.new('3.4.0'))
      expect(described_class.parse('3.0.0-beta.2')).to eq(Gem::Version.new('3.0.0'))
    end

    it 'returns nil when there is no version number' do
      expect(described_class.parse('surrealdb')).to be_nil
      expect(described_class.parse(nil)).to be_nil
    end
  end

  describe '.supported?' do
    it 'accepts 3.x and 4.x' do
      %w[surrealdb-3.0.0 surrealdb-3.3.4 surrealdb-3.4.0-nightly+20261014 surrealdb-4.0.0 surrealdb-4.9.12].each do |v|
        expect(described_class.supported?(v)).to be(true), v
      end
    end

    it 'refuses 2.x, 5.0 and later, and versions it cannot read' do
      %w[surrealdb-2.7.0 surrealdb-5.0.0 surrealdb-5.0.0-alpha surrealdb-6.1.0 surrealdb].each do |v|
        expect(described_class.supported?(v)).to be(false), v
      end
    end
  end

  describe '.check!' do
    it 'names the version and the supported range' do
      expect { described_class.check!('surrealdb-2.7.0') }.to raise_error(SurrealDB::UnsupportedVersionError) { |e|
        expect(e.version).to eq('surrealdb-2.7.0')
        expect(e.message).to include('3.0.0', '5.0.0', 'version_check: false')
      }
    end
  end
end

RSpec.describe SurrealDB::Client, '#connect version check' do
  let(:connection) do
    instance_double(SurrealDB::Connections::HTTP, connect: nil, close: nil, send_request: reported)
  end

  before { allow(SurrealDB::Connections::HTTP).to receive(:new).and_return(connection) }

  context 'with a supported server' do
    let(:reported) { 'surrealdb-3.3.4' }

    it 'connects and remembers the version' do
      client = described_class.new('http://localhost:8000').connect
      expect(client.server_version).to eq('surrealdb-3.3.4')
      expect(connection).not_to have_received(:close)
    end
  end

  context 'with an unsupported server' do
    let(:reported) { 'surrealdb-2.7.0' }

    it 'refuses it and closes the connection' do
      expect { described_class.new('http://localhost:8000').connect }
        .to raise_error(SurrealDB::UnsupportedVersionError)
      expect(connection).to have_received(:close)
    end

    it 'connects anyway with version_check: false' do
      client = described_class.new('http://localhost:8000', version_check: false).connect
      expect(client.server_version).to eq('surrealdb-2.7.0')
    end
  end
end
