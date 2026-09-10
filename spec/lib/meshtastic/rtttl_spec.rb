# frozen_string_literal: true

require 'spec_helper'

describe Meshtastic::RTTTL do
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

  it 'sets a ringtone via Admin' do
    serial_obj = fake_serial_obj
    described_class.set(serial_obj: serial_obj, ringtone: 'beep:d=4,o=5,b=120:16c6')
    frame = serial_obj[:written]
    packet = Meshtastic::ToRadio.decode(frame.byteslice(4, (frame.getbyte(2) << 8) + frame.getbyte(3))).packet
    admin = Meshtastic::AdminMessage.decode(packet.decoded.payload)
    expect(admin.set_ringtone_message).to eq('beep:d=4,o=5,b=120:16c6')
  end
end
