# frozen_string_literal: true

require 'spec_helper'

describe Meshtastic::Position do
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
    { serial_conn: serial_conn, written: written, my_node_num: 0xb0b }
  end

  it 'sends a POSITION_APP packet with scaled lat/lon' do
    serial_obj = fake_serial_obj
    described_class.transmit(serial_obj: serial_obj, lat: 37.7749, lon: -122.4194)
    frame = serial_obj[:written]
    packet = Meshtastic::ToRadio.decode(frame.byteslice(4, (frame.getbyte(2) << 8) + frame.getbyte(3))).packet
    expect(packet.decoded.portnum).to eq(:POSITION_APP)
    position = Meshtastic::Position.decode(packet.decoded.payload)
    expect(position.latitude_i).to eq(377_749_000)
    expect(position.longitude_i).to eq(-1_224_194_000)
  end

  it 'prints usage without raising' do
    expect { described_class.help }.to output(/USAGE/).to_stdout
  end
end
