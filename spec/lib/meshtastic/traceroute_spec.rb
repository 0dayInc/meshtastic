# frozen_string_literal: true

require 'spec_helper'

describe Meshtastic::Traceroute do
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

  it 'sends an empty RouteDiscovery on TRACEROUTE_APP' do
    serial_obj = fake_serial_obj
    described_class.send(serial_obj: serial_obj, to: '!aabbccdd')
    frame = serial_obj[:written]
    packet = Meshtastic::ToRadio.decode(frame.byteslice(4, (frame.getbyte(2) << 8) + frame.getbyte(3))).packet
    expect(packet.decoded.portnum).to eq(:TRACEROUTE_APP)
    expect(Meshtastic::RouteDiscovery.decode(packet.decoded.payload)).to be_a(Meshtastic::RouteDiscovery)
  end
end
