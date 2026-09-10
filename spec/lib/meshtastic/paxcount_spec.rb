# frozen_string_literal: true

require 'spec_helper'

describe Meshtastic::Paxcount do
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

  it 'transmits PAXCOUNTER_APP counts' do
    serial_obj = fake_serial_obj
    described_class.transmit(serial_obj: serial_obj, wifi: 3, ble: 2)
    frame = serial_obj[:written]
    packet = Meshtastic::ToRadio.decode(frame.byteslice(4, (frame.getbyte(2) << 8) + frame.getbyte(3))).packet
    expect(packet.decoded.portnum).to eq(:PAXCOUNTER_APP)
    count = Meshtastic::Paxcount.decode(packet.decoded.payload)
    expect(count.wifi).to eq(3)
    expect(count.ble).to eq(2)
  end
end
