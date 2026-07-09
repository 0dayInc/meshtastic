# frozen_string_literal: true

require 'spec_helper'

describe Meshtastic::SerialInterface do
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

  describe '.disconnect' do
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
