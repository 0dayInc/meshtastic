# frozen_string_literal: true

require 'spec_helper'

describe Meshtastic::Bluetooth do
  let(:connection) do
    Class.new do
      attr_reader :writes, :incoming

      def initialize
        @writes = []
        @incoming = Queue.new
        @closed = false
      end

      def connect
        self
      end

      def write(bytes)
        raise IOError, 'disconnected' if @closed

        @writes << bytes
        bytes.bytesize
      end

      def read
        raise IOError, 'disconnected' if @closed

        @incoming.pop(true)
      rescue ThreadError
        ''.b
      end

      def close
        @closed = true
      end

      def closed?
        @closed
      end
    end.new
  end

  before do
    backend = Class.new
    stub_const('Meshtastic::Bluetooth::BlueZ', backend)
    allow(backend).to receive(:new).with(address: 'AA:BB:CC:DD:EE:FF', adapter: 'hci0', timeout: 15).and_return(connection)
  end

  after do
    described_class.disconnect(bluetooth_obj: @bluetooth_obj) if @bluetooth_obj
  end

  def connect(opts = {})
    @bluetooth_obj = described_class.connect({ address: 'AA:BB:CC:DD:EE:FF', want_config: false }.merge(opts))
  end

  it 'writes text as a raw ToRadio protobuf without UART framing' do
    handle = connect
    size = described_class.send_text(bluetooth_obj: handle, text: 'hello', to: '!83726fb1', channel: 0, want_ack: true)
    bytes = connection.writes.last
    packet = Meshtastic::ToRadio.decode(bytes).packet
    expect(size).to eq(bytes.bytesize)
    expect(packet.decoded.payload).to eq('hello')
    expect(packet.to).to eq(0x83726fb1)
    expect(packet.channel).to eq(0)
    expect(packet.want_ack).to be(true)
    expect(packet.encrypted).to eq('')
    expect(packet.from).to eq(0)
  end

  it 'receives FromRadio messages and completes the matching configuration handshake' do
    handle = connect(want_config: true)
    config_id = Meshtastic::ToRadio.decode(connection.writes.first).want_config_id
    expect(config_id).to be_positive
    info = Meshtastic::FromRadio.new(my_info: Meshtastic::MyNodeInfo.new(my_node_num: 123))
    connection.incoming << info.to_proto
    connection.incoming << Meshtastic::FromRadio.new(config_complete_id: config_id).to_proto
    expect(described_class.wait_for_config(bluetooth_obj: handle, timeout: 1)).to eq(handle)
    expect(handle[:my_node_num]).to eq(123)
    expect(described_class.recv_from_radio(bluetooth_obj: handle, timeout: 0)).to eq(info)
  end

  it 'subscribes to filtered text messages with the same decoded hashes as Serial' do
    handle = connect
    %w[hidden hello].each do |text|
      connection.incoming << Meshtastic::FromRadio.new(packet: Meshtastic::MeshPacket.new(
        from: 123, to: 0xffffffff, channel: 0,
        decoded: Meshtastic::Data.new(portnum: :TEXT_MESSAGE_APP, payload: text)
      )).to_proto
    end
    received = Timeout.timeout(1) do
      described_class.subscribe(bluetooth_obj: handle, include: 'TEXT_MESSAGE_APP', exclude: 'hidden', include_raw: true) do |message|
        break message
      end
    end
    expect(received.dig(:packet, :decoded, :payload)).to eq('hello')
    expect(received.dig(:packet, :node_id_from)).to eq('!7b')
    expect(Meshtastic::FromRadio.decode(received.dig(:packet, :raw_packet)).packet.from).to eq(123)
  end

  it 'sends binary data to a shared channel with device-managed encryption' do
    handle = connect
    data = Meshtastic::Data.new(portnum: :PRIVATE_APP, payload: "\x00\xff".b)
    described_class.send_data(bluetooth_obj: handle, data: data, channel: 2)
    packet = Meshtastic::ToRadio.decode(connection.writes.last).packet
    expect(packet.to).to eq(0xffffffff)
    expect(packet.channel).to eq(2)
    expect(packet.decoded).to eq(data)
  end

  it 'drains messages and snapshots or clears per-connection console and protobuf buffers' do
    handle = connect
    message = Meshtastic::FromRadio.new(log_record: Meshtastic::LogRecord.new(message: 'BLE log'))
    connection.incoming << message.to_proto
    expect(described_class.recv_from_radio(bluetooth_obj: handle, timeout: 1)).to eq(message)
    expect(described_class.drain_from_radio(bluetooth_obj: handle)).to eq([])
    expect(described_class.dump_stdout_data(bluetooth_obj: handle, type: :console)).to eq("BLE log\n")
    expect(described_class.dump_stdout_data(type: :proto)).to eq([message.to_h])
    yielded = []
    described_class.dump_stdout_data(bluetooth_obj: handle, type: :console) { |line| yielded << line }
    expect(yielded).to eq(['BLE log'])
    described_class.flush_data(bluetooth_obj: handle, type: :console)
    expect(described_class.dump_stdout_data(bluetooth_obj: handle, type: :console)).to eq('')
  end

  it 'cleans up a failed GATT write without recursive disconnect attempts' do
    handle = connect
    allow(connection).to receive(:write).and_raise(IOError, 'GATT write failed')
    expect { described_class.send_text(bluetooth_obj: handle, text: 'hello') }.to raise_error(IOError, 'GATT write failed')
    expect(connection.closed?).to be(true)
    expect(handle[:rx_thread].alive?).to be(false)
    expect(handle[:from_radio_queue].closed?).to be(true)
  end

  it 'scans with the selected adapter and bounded discovery timeout' do
    devices = [{ address: 'AA:BB:CC:DD:EE:FF', name: 'Meshtastic_test', paired: true }]
    expect(described_class::BlueZ).to receive(:scan).with({ adapter: 'hci1', timeout: 2 }).and_return(devices)
    expect(described_class.scan(adapter: 'hci1', timeout: 2)).to eq(devices)
  end

  it 'prints usage without raising' do
    expect { described_class.help }.to output(/USAGE/).to_stdout
  end
end
