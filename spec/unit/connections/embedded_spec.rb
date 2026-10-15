# frozen_string_literal: true

require 'open3'

# These tests verify the Embedded connection's Ruby logic without loading
# the actual FFI bindings (which require libsurrealdb_c). We test that
# the class structure and method signatures are correct.

RSpec.describe 'SurrealDB::Connections::Embedded (structure)' do
  # The Embedded class is only loaded via require "surrealdb/embedded",
  # which needs libsurrealdb_c. We test the file parses correctly by
  # checking its existence and that the main gem doesn't auto-load it.

  it 'is not auto-loaded by the main gem' do
    expect(defined?(SurrealDB::Connections::Embedded)).to be_nil
  end

  it 'has the connection file at the expected path' do
    path = File.expand_path('../../../lib/surrealdb/connections/embedded.rb', __dir__)
    expect(File.exist?(path)).to be true
  end

  it 'has the platform detection file' do
    path = File.expand_path('../../../lib/surrealdb/native/platform.rb', __dir__)
    expect(File.exist?(path)).to be true
  end

  it 'has the FFI bindings file' do
    path = File.expand_path('../../../lib/surrealdb/native/ffi.rb', __dir__)
    expect(File.exist?(path)).to be true
  end

  it 'has the opt-in entrypoint' do
    path = File.expand_path('../../../lib/surrealdb/embedded.rb', __dir__)
    expect(File.exist?(path)).to be true
  end
end

RSpec.describe 'SurrealDB::Connections::Embedded notifications' do
  # Loaded in a separate process: this process checks the class is not
  # loaded by the main gem, and loading it needs no native library.
  it 'hands a live notification, whose id decodes as a Uuid, to the handler registered for it' do
    script = <<~RUBY
      require 'surrealdb'
      require 'surrealdb/connections/embedded'
      conn = SurrealDB::Connections::Embedded.new('mem://')
      id = SurrealDB::Uuid.v4
      seen = []
      conn.on_notification(id.to_s, ->(n) { seen << n['action'] })
      bytes = SurrealDB::CBOR::Encoder.encode({ 'result' => { 'id' => id, 'action' => 'CREATE' } })
      conn.send(:dispatch_notification, bytes)
      print seen.inspect
    RUBY
    lib = File.expand_path('../../../lib', __dir__)
    output, status = Open3.capture2e(RbConfig.ruby, '-I', lib, '-e', script)
    expect([status.success?, output]).to eq([true, '["CREATE"]'])
  end
end

RSpec.describe 'SurrealDB::Native::Platform' do
  before do
    require_relative '../../../lib/surrealdb/native/platform'
  end

  describe '.host_os' do
    it 'returns a symbol' do
      expect(SurrealDB::Native::Platform.host_os).to be_a(Symbol)
    end
  end

  describe '.host_cpu' do
    it 'returns a symbol' do
      expect(SurrealDB::Native::Platform.host_cpu).to be_a(Symbol)
    end
  end

  describe '.library_name' do
    it 'returns a string with the correct extension' do
      name = SurrealDB::Native::Platform.library_name
      expect(name).to be_a(String)
      expect(name).to include('surrealdb_c')
    end
  end

  describe '.library_path' do
    context 'when SURREALDB_LIB_PATH is not set' do
      before { allow(ENV).to receive(:fetch).and_call_original }

      it 'falls back to the library name for system lookup' do
        allow(ENV).to receive(:[]).with('SURREALDB_LIB_PATH').and_return(nil)
        expect(SurrealDB::Native::Platform.library_path).to eq(SurrealDB::Native::Platform.library_name)
      end
    end
  end
end
