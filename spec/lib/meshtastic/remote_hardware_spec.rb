# frozen_string_literal: true

require 'spec_helper'

describe Meshtastic::RemoteHardware do
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

  it 'writes GPIO bits on REMOTE_HARDWARE_APP' do
    serial_obj = fake_serial_obj
    described_class.write_gpios(serial_obj: serial_obj, gpio_mask: 0x01, gpio_value: 0x01)
    frame = serial_obj[:written]
    packet = Meshtastic::ToRadio.decode(frame.byteslice(4, (frame.getbyte(2) << 8) + frame.getbyte(3))).packet
    expect(packet.decoded.portnum).to eq(:REMOTE_HARDWARE_APP)
    hw = Meshtastic::HardwareMessage.decode(packet.decoded.payload)
    expect(hw.type).to eq(:WRITE_GPIOS)
    expect(hw.gpio_mask).to eq(1)
    expect(hw.gpio_value).to eq(1)
  end
end
