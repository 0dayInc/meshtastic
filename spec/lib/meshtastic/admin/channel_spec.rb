# frozen_string_literal: true

require 'spec_helper'

describe Meshtastic::Admin::Channel do
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
    Meshtastic::AdminMessage.decode(Meshtastic::ToRadio.decode(body).packet.decoded.payload)
  end

  it 'requests a channel by index via Admin' do
    serial_obj = fake_serial_obj
    described_class.get(serial_obj: serial_obj, index: 1)
    expect(decode_admin(serial_obj).get_channel_request).to eq(1)
  end

  it 'sets a Channel protobuf including settings and role' do
    serial_obj = fake_serial_obj
    settings = described_class.build_settings(name: 'LongFast', uplink_enabled: true)
    described_class.set(serial_obj: serial_obj, index: 0, role: :PRIMARY, settings: settings)
    channel = decode_admin(serial_obj).set_channel
    expect(channel.index).to eq(0)
    expect(channel.role).to eq(:PRIMARY)
    expect(channel.settings.name).to eq('LongFast')
    expect(channel.settings.uplink_enabled).to be true
  end

  it 'prints usage without raising' do
    expect { described_class.help }.to output(/USAGE/).to_stdout
  end
end
