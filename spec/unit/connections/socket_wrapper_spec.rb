# frozen_string_literal: true

RSpec.describe SurrealDB::Connections::SocketWrapper do
  it 'gives up at the deadline even when every write takes a little' do
    socket = Object.new
    def socket.write_nonblock(*, **)
      sleep 0.01
      1
    end
    wrapper = described_class.new(socket, 'ws://localhost:8000/rpc')
    wrapper.deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.1
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect { wrapper.write('x' * 1000) }.to raise_error(described_class::WriteTimeout)
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1
  end
end
