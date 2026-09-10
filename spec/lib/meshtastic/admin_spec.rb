# frozen_string_literal: true

require 'spec_helper'

describe Meshtastic::Admin do
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

  def decode_admin(serial_obj)
    frame = serial_obj[:written]
    body = frame.byteslice(4, (frame.getbyte(2) << 8) + frame.getbyte(3))
    packet = Meshtastic::ToRadio.decode(body).packet
    [packet, Meshtastic::AdminMessage.decode(packet.decoded.payload)]
  end

  it 'sends a reboot AdminMessage on ADMIN_APP' do
    serial_obj = fake_serial_obj
    described_class.reboot(serial_obj: serial_obj, seconds: 7)
    packet, admin = decode_admin(serial_obj)
    expect(packet.decoded.portnum).to eq(:ADMIN_APP)
    expect(admin.reboot_seconds).to eq(7)
  end

  it 'sends a set_owner AdminMessage' do
    serial_obj = fake_serial_obj
    described_class.set_owner(serial_obj: serial_obj, long_name: 'Test Node', short_name: 'TN')
    _packet, admin = decode_admin(serial_obj)
    expect(admin.set_owner.long_name).to eq('Test Node')
    expect(admin.set_owner.short_name).to eq('TN')
  end

  it 'prints usage without raising' do
    expect { described_class.help }.to output(/USAGE/).to_stdout
  end
end
