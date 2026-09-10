# frozen_string_literal: true

require 'spec_helper'

describe Meshtastic::Admin::Config do
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

  it 'requests LoRa config via Admin' do
    serial_obj = fake_serial_obj
    described_class.get(serial_obj: serial_obj, config_type: :LORA_CONFIG)
    expect(decode_admin(serial_obj).get_config_request).to eq(:LORA_CONFIG)
  end

  it 'sets a Config protobuf' do
    serial_obj = fake_serial_obj
    config = Meshtastic::Config.new
    config.device = Meshtastic::Config::DeviceConfig.new(role: :CLIENT)
    described_class.set(serial_obj: serial_obj, config: config)
    expect(decode_admin(serial_obj).set_config.device.role).to eq(:CLIENT)
  end

  it 'requests each ConfigType via named getters' do
    serial_obj = fake_serial_obj
    described_class.get_lora(serial_obj: serial_obj)
    expect(decode_admin(serial_obj).get_config_request).to eq(:LORA_CONFIG)
  end

  it 'prints usage without raising' do
    expect { described_class.help }.to output(/USAGE/).to_stdout
  end
end
