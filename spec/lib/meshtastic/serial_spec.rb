# frozen_string_literal: true

require 'spec_helper'
require 'pty'

describe Meshtastic::Serial do # rubocop:disable Metrics/BlockLength
  def with_serial_link(opts = {})
    PTY.open do |device, host|
      serial_obj = described_class.connect({ block_dev: host.path, want_config: false }.merge(opts))
      begin
        yield serial_obj, device
      ensure
        described_class.disconnect(serial_obj: serial_obj)
      end
    end
  end

  def radio_frame(message)
    body = message.to_proto
    [Meshtastic::START1, Meshtastic::START2, body.bytesize].pack('CCn') + body
  end

  describe '.wait_for_config' do
    it 'times out rather than accepting a mismatched configuration ID' do
      with_serial_link(want_config: true) do |serial_obj, device|
        wrong_id = serial_obj[:config_id] ^ 1
        device.write(radio_frame(Meshtastic::FromRadio.new(config_complete_id: wrong_id)))
        expect do
          described_class.wait_for_config(serial_obj: serial_obj, timeout: 0.05)
        end.to raise_error(Timeout::Error, /No configuration response/)
      end
    end

    it 'waits for the matching configuration response without consuming received messages' do
      with_serial_link(want_config: true) do |serial_obj, device|
        request = Timeout.timeout(1) do
          expect(device.read(32)).to eq(([Meshtastic::START2] * 32).pack('C*'))
          header = device.read(4)
          Meshtastic::ToRadio.decode(device.read(header.unpack('CCn').last))
        end
        device.write(radio_frame(Meshtastic::FromRadio.new(my_info: Meshtastic::MyNodeInfo.new(my_node_num: 123))))
        device.write(radio_frame(Meshtastic::FromRadio.new(config_complete_id: request.want_config_id)))
        expect(described_class.wait_for_config(serial_obj: serial_obj, timeout: 1)).to eq(serial_obj)
        expect(serial_obj[:my_node_num]).to eq(123)
        expect(described_class.recv_from_radio(serial_obj: serial_obj, timeout: 0).payload_variant).to eq(:my_info)
      end
    end
  end

  describe 'serial reception' do
    it 'receives after an idle interval longer than the UART read timeout' do
      with_serial_link do |serial_obj, device|
        expect(described_class.recv_from_radio(serial_obj: serial_obj, timeout: 0.6)).to be_nil
        message = Meshtastic::FromRadio.new(my_info: Meshtastic::MyNodeInfo.new(my_node_num: 123))
        device.write(radio_frame(message))
        expect(described_class.recv_from_radio(serial_obj: serial_obj, timeout: 1)).to eq(message)
      end
    end

    it 'skips oversized headers and malformed protobufs before the next valid frame' do
      with_serial_link do |serial_obj, device|
        message = Meshtastic::FromRadio.new(my_info: Meshtastic::MyNodeInfo.new(my_node_num: 123))
        expect do
          device.write([Meshtastic::START1, Meshtastic::START2, 513].pack('CCn'))
          device.write([Meshtastic::START1, Meshtastic::START2, 1, 255].pack('CCnC'))
          device.write(radio_frame(message))
          expect(described_class.recv_from_radio(serial_obj: serial_obj, timeout: 1)).to eq(message)
        end.to output(/failed to decode FromRadio/).to_stderr
      end
    end

    it 'unblocks an indefinite receive when disconnected' do
      with_serial_link do |serial_obj, _device|
        receiver = Thread.new { described_class.recv_from_radio(serial_obj: serial_obj, timeout: nil) }
        begin
          described_class.disconnect(serial_obj: serial_obj)
          expect(receiver.join(1)).to eq(receiver)
          expect(receiver.value).to be_nil
          expect(described_class.drain_from_radio(serial_obj: serial_obj)).to eq([])
        ensure
          receiver.kill.join
        end
      end
    end

    it 'treats text payloads as UTF-8, never as nested protobuf messages' do
      with_serial_link do |serial_obj, device|
        text = "\n\x02hi"
        device.write(radio_frame(Meshtastic::FromRadio.new(packet: Meshtastic::MeshPacket.new(
          decoded: Meshtastic::Data.new(portnum: :TEXT_MESSAGE_APP, payload: text)
        ))))
        Timeout.timeout(1) do
          described_class.subscribe(serial_obj: serial_obj) do |message|
            expect(message.dig(:packet, :decoded, :payload)).to eq(text)
            expect(message.dig(:packet, :decoded, :payload).encoding).to eq(Encoding::UTF_8)
            break
          end
        end
      end
    end

    it 'reports an unplugged device to blocked receivers' do
      with_serial_link do |serial_obj, device|
        device.close
        expect { described_class.recv_from_radio(serial_obj: serial_obj, timeout: 1) }.to raise_error(IOError)
      end
    end

    it 'keeps independent receive queues and disconnect state for each device' do
      with_serial_link do |first, first_device|
        with_serial_link do |second, second_device|
          first_message = Meshtastic::FromRadio.new(my_info: Meshtastic::MyNodeInfo.new(my_node_num: 1))
          second_message = Meshtastic::FromRadio.new(my_info: Meshtastic::MyNodeInfo.new(my_node_num: 2))
          second_device.write(radio_frame(second_message))
          first_device.write(radio_frame(first_message))
          expect(described_class.recv_from_radio(serial_obj: first, timeout: 1)).to eq(first_message)
          expect(described_class.recv_from_radio(serial_obj: second, timeout: 1)).to eq(second_message)
          described_class.disconnect(serial_obj: first)
          second_device.write(radio_frame(second_message))
          expect(described_class.recv_from_radio(serial_obj: second, timeout: 1)).to eq(second_message)
        end
      end
    end

    it 'returns immediately when polling an empty queue with timeout zero' do
      with_serial_link do |_serial_obj, _device|
        result = Timeout.timeout(0.2) { described_class.recv_from_radio(timeout: 0) }
        expect(result).to be_nil
      end
    end

    it 'yields received text through subscription filters' do
      with_serial_link do |serial_obj, device|
        %w[hidden hello].each do |text|
          device.write(radio_frame(Meshtastic::FromRadio.new(packet: Meshtastic::MeshPacket.new(
            from: 123, decoded: Meshtastic::Data.new(portnum: :TEXT_MESSAGE_APP, payload: text)
          ))))
        end
        received = nil
        Timeout.timeout(2) do
          described_class.subscribe(serial_obj: serial_obj, include: 'TEXT_MESSAGE_APP', exclude: 'hidden') do |message|
            received = message.dig(:packet, :decoded, :payload)
            break
          end
        end
        expect(received).to eq('hello')
      end
    end

    it 'resynchronizes overlapping start bytes and receives a fragmented text packet' do
      with_serial_link do |_serial_obj, device|
        message = Meshtastic::FromRadio.new(packet: Meshtastic::MeshPacket.new(
          from: 123, decoded: Meshtastic::Data.new(portnum: :TEXT_MESSAGE_APP, payload: 'hello')
        ))
        device.write("boot\n\x94".b)
        radio_frame(message).each_byte { |byte| device.write([byte].pack('C')) }
        expect(described_class.recv_from_radio(timeout: 1)).to eq(message)
      end
    end
  end

  def fake_serial_obj
    written = +''.b
    serial_conn = Object.new
    serial_conn.define_singleton_method(:write) do |b|
      written << b
      b.bytesize
    end
    serial_conn.define_singleton_method(:flush) { true }
    serial_conn.define_singleton_method(:closed?) { false }
    serial_conn.define_singleton_method(:close) { true }
    serial_conn.define_singleton_method(:written) { written }
    { serial_conn: serial_conn, written: written, my_node_num: 0xb0b }
  end

  describe '.send_to_radio' do
    it 'writes the entire frame when the transport accepts only part of each write' do
      serial_obj = fake_serial_obj
      written = serial_obj[:written]
      serial_obj[:serial_conn].define_singleton_method(:write) do |bytes|
        written << bytes.byteslice(0, 2)
        [bytes.bytesize, 2].min
      end
      message = Meshtastic::ToRadio.new(want_config_id: 42)
      described_class.send_to_radio(serial_obj: serial_obj, to_radio: message)
      expect(written).to eq(radio_frame(message))
    end

    it 'frames a ToRadio with START1/START2 and big-endian length' do
      serial_obj = fake_serial_obj
      to_radio = Meshtastic::ToRadio.new
      to_radio.want_config_id = 42
      body = to_radio.to_proto

      described_class.send_to_radio(serial_obj: serial_obj, to_radio: to_radio)
      frame = serial_obj[:serial_conn].written

      expect(frame.getbyte(0)).to eq(Meshtastic::START1)
      expect(frame.getbyte(1)).to eq(Meshtastic::START2)
      expect((frame.getbyte(2) << 8) + frame.getbyte(3)).to eq(body.bytesize)
      expect(frame.byteslice(4, body.bytesize)).to eq(body)
    end

    it 'accepts a pre-serialized String body' do
      serial_obj = fake_serial_obj
      body = Meshtastic::ToRadio.new.tap { |t| t.want_config_id = 7 }.to_proto
      described_class.send_to_radio(serial_obj: serial_obj, to_radio: body)
      frame = serial_obj[:serial_conn].written
      expect(frame.bytesize).to eq(4 + body.bytesize)
    end
  end

  describe '.send_text' do
    it 'rejects text exceeding the byte limit without closing the connection' do
      serial_obj = fake_serial_obj
      expect do
        described_class.send_text(serial_obj: serial_obj, text: 'é' * Meshtastic::Constants::DATA_PAYLOAD_LEN)
      end.to raise_error(ArgumentError, /Bytes/)
      expect(serial_obj[:written]).to be_empty
      expect(serial_obj[:closing]).to be_nil
    end

    it 'lets the firmware supply the sender before my_info arrives' do
      serial_obj = fake_serial_obj
      serial_obj[:my_node_num] = nil
      described_class.send_text(serial_obj: serial_obj, text: 'ping')
      expect(Meshtastic::ToRadio.decode(serial_obj[:written].byteslice(4..)).packet.from).to eq(0)
    end

    it 'writes a decoded ToRadio mesh packet for the radio to encrypt' do
      serial_obj = fake_serial_obj
      described_class.send_text(
        serial_obj: serial_obj,
        text: 'ping',
        to: '!ffffffff',
        channel: 0
      )
      frame = serial_obj[:serial_conn].written
      body_len = (frame.getbyte(2) << 8) + frame.getbyte(3)
      tr = Meshtastic::ToRadio.decode(frame.byteslice(4, body_len))

      expect(tr.packet).not_to be_nil
      expect(tr.packet.decoded).not_to be_nil
      expect(tr.packet.decoded.payload).to eq('ping')
      expect(tr.packet.encrypted.to_s).to eq('')
      expect(tr.packet.from).to eq(0xb0b)
    end
  end

  describe '.send_data' do
    it 'sends a binary application packet over a real serial transport' do
      with_serial_link do |serial_obj, device|
        data = Meshtastic::Data.new(portnum: :PRIVATE_APP, payload: "\x00\xff".b)
        described_class.send_data(serial_obj: serial_obj, data: data, to: '!0000007b', channel: 1, want_ack: true)
        packet = Timeout.timeout(1) do
          device.read(32)
          header = device.read(4)
          expect(header.bytes.first(2)).to eq([Meshtastic::START1, Meshtastic::START2])
          Meshtastic::ToRadio.decode(device.read(header.unpack('CCn').last)).packet
        end
        expect(packet.decoded).to eq(data)
        expect(packet.to).to eq(123)
        expect(packet.from).to eq(0)
        expect(packet.channel).to eq(1)
        expect(packet.want_ack).to be(true)
        expect(packet.id).to be_positive
      end
    end
  end

  describe '.disconnect' do
    it 'closes a failed transport without recursively sending disconnect packets' do
      serial_obj = fake_serial_obj
      writes = 0
      serial_obj[:serial_conn].define_singleton_method(:write) do |_bytes|
        writes += 1
        raise IOError, 'disconnected USB device'
      end
      expect(serial_obj[:serial_conn]).to receive(:close)
      expect { described_class.disconnect(serial_obj: serial_obj) }.not_to raise_error
      expect(writes).to eq(1)
    end

    it 'returns nil and closes the serial connection' do
      serial_obj = fake_serial_obj
      expect(described_class.disconnect(serial_obj: serial_obj)).to be_nil
    end
  end

  describe '.help' do
    it 'prints usage without raising' do
      expect { described_class.help }.to output(/USAGE/).to_stdout
    end
  end
end
