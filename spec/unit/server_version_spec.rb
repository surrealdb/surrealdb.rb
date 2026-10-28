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

    it 'takes the first three numbers that follow each other' do
      expect(described_class.parse('v1..2.3.4.5')).to eq(Gem::Version.new('2.3.4'))
      expect(described_class.parse('build 7, version 12.3.4.5')).to eq(Gem::Version.new('12.3.4'))
      expect(described_class.parse('1.2. 3.4')).to be_nil
    end

    it 'reads a long run of digits in linear time' do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect(described_class.parse('9' * 200_000)).to be_nil
      expect(described_class.parse('9.' * 100_000)).to eq(Gem::Version.new('9.9.9'))
      expect(described_class.parse("#{'9.9' * 50_000}x")).to eq(Gem::Version.new('9.99.99'))
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1
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

  context 'when asking for the version fails' do
    let(:reported) { nil }

    [SurrealDB::TimeoutError, SurrealDB::ServerError, SurrealDB::ProtocolError].each do |error|
      it "closes the connection on #{error.name.split('::').last}" do
        allow(connection).to receive(:send_request).and_raise(error, 'no answer')
        expect { described_class.new('http://localhost:8000').connect }.to raise_error(error)
        expect(connection).to have_received(:close)
      end
    end

    it 'closes the connection opened by SurrealDB.connect, which never returns the client' do
      allow(connection).to receive(:send_request).and_raise(SurrealDB::TimeoutError, 'no answer')
      expect { SurrealDB.connect('http://localhost:8000') { nil } }.to raise_error(SurrealDB::TimeoutError)
      expect(connection).to have_received(:close).once
    end

    it 'raises the original error when closing fails too' do
      allow(connection).to receive(:send_request).and_raise(SurrealDB::TimeoutError, 'no answer')
      allow(connection).to receive(:close).and_raise(IOError, 'already closed')
      expect { described_class.new('http://localhost:8000').connect }.to raise_error(SurrealDB::TimeoutError)
    end
  end
end

RSpec.describe SurrealDB::Client, '#server_version after a reconnect' do
  it 'checks the server a reconnect reached, on the new connection' do
    client = described_class.new('ws://localhost:8000')
    check = client.connection.instance_variable_get(:@on_reconnect)
    fresh = instance_double(SurrealDB::Connections::WebSocket, send_request: 'surrealdb-5.0.0')
    expect { check.call(fresh) }.to raise_error(SurrealDB::UnsupportedVersionError)
    expect(client.server_version).to eq('surrealdb-5.0.0')
    expect(fresh).to have_received(:send_request).with('version')
  end
end
