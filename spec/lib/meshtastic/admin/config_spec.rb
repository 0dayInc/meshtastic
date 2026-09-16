# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Meshtastic::Admin::Config do
  it 'documents transport_obj rather than legacy connection keywords' do
    expect { described_class.help }.to output(/transport_obj:/).to_stdout
    expect { described_class.help }.not_to output(/serial_obj:|bluetooth_obj:|tcp_obj:|mqtt_obj:/).to_stdout
  end
end

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

  it 'rejects legacy connection keys rather than silently filtering them' do
    %i[serial_obj bluetooth_obj tcp_obj mqtt_obj].each do |key|
      handle = fake_serial_obj
      expect { described_class.set_device_ui(transport_obj: handle, key => nil, device_ui: {}) }
        .to raise_error(ArgumentError, /#{key}/)
      expect(handle[:written]).to be_empty
    end
  end

  it 'requests LoRa config via Admin' do
    serial_obj = fake_serial_obj
    described_class.get(transport_obj: serial_obj, config_type: :LORA_CONFIG)
    expect(decode_admin(serial_obj).get_config_request).to eq(:LORA_CONFIG)
  end

  it 'sets a Config protobuf' do
    serial_obj = fake_serial_obj
    config = Meshtastic::Config.new
    config.device = Meshtastic::Config::DeviceConfig.new(role: :CLIENT)
    described_class.set(transport_obj: serial_obj, config: config)
    expect(decode_admin(serial_obj).set_config.device.role).to eq(:CLIENT)
  end

  it 'requests each ConfigType via named getters' do
    serial_obj = fake_serial_obj
    described_class.get_lora(transport_obj: serial_obj)
    expect(decode_admin(serial_obj).get_config_request).to eq(:LORA_CONFIG)
  end

  Meshtastic::Config.descriptor.each do |field|
    next if %w[sessionkey device_ui].include?(field.name)

    it "writes the #{field.name} section through real serial framing" do
      serial_obj = fake_serial_obj
      section = field.subtype.msgclass.new
      described_class.public_send("set_#{field.name}", transport_obj: serial_obj, field.name.to_sym => section)
      config = decode_admin(serial_obj).set_config
      expect(config.payload_variant).to eq(field.name.to_sym)
      expect(config[field.name]).to eq(section)
    end
  end

  it 'rejects an empty config before writing bytes' do
    serial_obj = fake_serial_obj
    expect { described_class.set(transport_obj: serial_obj, config: Meshtastic::Config.new) }.to raise_error(ArgumentError)
    expect(serial_obj[:written]).to be_empty
  end

  Meshtastic::Config.descriptor.each do |field|
    next if %w[sessionkey device_ui].include?(field.name)

    it "accepts a field hash for #{field.name}" do
      serial_obj = fake_serial_obj
      described_class.public_send("set_#{field.name}", transport_obj: serial_obj, field.name.to_sym => {})
      expect(decode_admin(serial_obj).set_config.payload_variant).to eq(field.name.to_sym)
    end

    it "rejects missing #{field.name} before writing bytes" do
      serial_obj = fake_serial_obj
      expect { described_class.public_send("set_#{field.name}", transport_obj: serial_obj) }.to(raise_error { |error| expect([ArgumentError, KeyError]).to include(error.class) })
      expect(serial_obj[:written]).to be_empty
    end
  end

  it 'uses dedicated device UI requests and stores instead of firmware no-op Config fields' do
    serial_obj = fake_serial_obj
    described_class.get_device_ui(transport_obj: serial_obj)
    expect(decode_admin(serial_obj).payload_variant).to eq(:get_ui_config_request)
    serial_obj = fake_serial_obj
    described_class.set_device_ui(transport_obj: serial_obj, device_ui: {})
    expect(decode_admin(serial_obj).payload_variant).to eq(:store_ui_config)
  end

  it 'rejects the read-only session-key placeholder without transmitting' do
    serial_obj = fake_serial_obj
    config = Meshtastic::Config.new(sessionkey: {})
    expect { described_class.set(transport_obj: serial_obj, config: config) }.to raise_error(ArgumentError, /request-only/)
    expect { described_class.set_sessionkey(transport_obj: serial_obj, sessionkey: {}) }.to raise_error(ArgumentError, /request-only/)
    expect(serial_obj[:written]).to be_empty
  end

  {
    device: :DEVICE_CONFIG, position: :POSITION_CONFIG, power: :POWER_CONFIG,
    network: :NETWORK_CONFIG, display: :DISPLAY_CONFIG, lora: :LORA_CONFIG,
    bluetooth: :BLUETOOTH_CONFIG, security: :SECURITY_CONFIG, sessionkey: :SESSIONKEY_CONFIG
  }.each do |section, config_type|
    it "requests #{section} using its protocol ConfigType" do
      serial_obj = fake_serial_obj
      described_class.public_send("get_#{section}", transport_obj: serial_obj)
      message = decode_admin(serial_obj)
      expect(message.payload_variant).to eq(:get_config_request)
      expect(message.get_config_request).to eq(config_type)
    end
  end

  it 'prints usage without raising' do
    expect { described_class.help }.to output(/USAGE/).to_stdout
  end
end
