# frozen_string_literal: true

require 'spec_helper'

describe Meshtastic::Storeforward do
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

  it 'sends STORE_FORWARD_APP history request' do
    serial_obj = fake_serial_obj
    described_class.send(serial_obj: serial_obj, rr: :CLIENT_HISTORY)
    frame = serial_obj[:written]
    packet = Meshtastic::ToRadio.decode(frame.byteslice(4, (frame.getbyte(2) << 8) + frame.getbyte(3))).packet
    expect(packet.decoded.portnum).to eq(:STORE_FORWARD_APP)
    expect(Meshtastic::StoreAndForward.decode(packet.decoded.payload).rr).to eq(:CLIENT_HISTORY)
  end
end
