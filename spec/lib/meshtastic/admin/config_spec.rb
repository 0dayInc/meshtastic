# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Meshtastic::Admin::Config do
  it 'documents transport_obj rather than legacy connection keywords' do
    expect { described_class.help }.to output(/transport_obj:/).to_stdout
    expect { described_class.help }.not_to output(/serial_obj:|bluetooth_obj:|tcp_obj:|mqtt_obj:/).to_stdout
  end
end

module AdminConfigSpecHelpers
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
end

describe Meshtastic::Admin::Config do
  include AdminConfigSpecHelpers

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
end

describe Meshtastic::Admin::Config, 'read-modify-readback helpers' do
  include AdminConfigSpecHelpers

  it 'updates signature policy with fresh correlated readback while preserving other security fields' do
    current = Meshtastic::Config.new(security: { serial_enabled: true, public_key: 'k' * 32 })
    handle = fake_serial_obj.merge(from_radio_queue: Queue.new, messages: [])
    handle[:serial_conn].define_singleton_method(:write) do |bytes|
      packet = Meshtastic::ToRadio.decode(bytes.byteslice(4..)).packet
      message = Meshtastic::AdminMessage.decode(packet.decoded.payload)
      handle[:messages] << message
      if message.payload_variant == :get_config_request
        payload = Meshtastic::AdminMessage.new(get_config_response: current).to_proto
        data = Meshtastic::Data.new(portnum: :ADMIN_APP, request_id: packet.id, payload: payload)
      else
        current = Meshtastic::Config.decode(message.set_config.to_proto)
        data = Meshtastic::Data.new(portnum: :ROUTING_APP, request_id: packet.id)
      end
      handle[:from_radio_queue] << Meshtastic::FromRadio.new(packet: Meshtastic::MeshPacket.new(from: packet.to, decoded: data))
      bytes.bytesize
    end
    result = described_class.set_packet_signature_policy(transport_obj: handle, policy: :PACKET_SIGNATURE_POLICY_STRICT)
    expect(current.security).to have_attributes(serial_enabled: true, public_key: 'k' * 32, packet_signature_policy: :PACKET_SIGNATURE_POLICY_STRICT)
    expect(handle[:messages].map(&:payload_variant)).to eq(%i[get_config_request set_config get_config_request])
    expect(result).to include(matched: true, reboot_requested: false)
    expect(result[:acknowledgment][:delivery]).to eq(:acknowledged)
    expect(result[:readback][:delivery]).to eq(:readback)
  end

  it 'sets local receive-only without resetting LoRa fields or issuing a reboot and reports mismatched readback' do
    [true, false].each do |apply|
      current = Meshtastic::Config.new(lora: { region: :US, hop_limit: 3, tx_enabled: true })
      handle = fake_serial_obj.merge(from_radio_queue: Queue.new, messages: [])
      handle[:serial_conn].define_singleton_method(:write) do |bytes|
        packet = Meshtastic::ToRadio.decode(bytes.byteslice(4..)).packet
        message = Meshtastic::AdminMessage.decode(packet.decoded.payload)
        handle[:messages] << message
        if message.payload_variant == :get_config_request
          data = Meshtastic::Data.new(portnum: :ADMIN_APP, request_id: packet.id,
                                      payload: Meshtastic::AdminMessage.new(get_config_response: current).to_proto)
        else
          current = message.set_config if apply
          data = Meshtastic::Data.new(portnum: :ROUTING_APP, request_id: packet.id)
        end
        handle[:from_radio_queue] << Meshtastic::FromRadio.new(packet: Meshtastic::MeshPacket.new(from: packet.to, decoded: data))
        bytes.bytesize
      end
      result = described_class.set_receive_only(transport_obj: handle, enabled: true)
      expect(result).to include(matched: apply, reboot_requested: false)
      expect(handle[:messages][1].set_config.lora).to have_attributes(region: :US, hop_limit: 3, tx_enabled: false)
      expect(handle[:messages].map(&:payload_variant)).to eq(%i[get_config_request set_config get_config_request])
    end
  end

  it 'rejects invalid policy and receive-only settings before any transmission' do
    handle = fake_serial_obj
    [99, nil, true, 'PACKET_SIGNATURE_POLICY_STRICT', :UNKNOWN].each do |policy|
      expect { described_class.set_packet_signature_policy(transport_obj: handle, policy: policy) }.to raise_error(ArgumentError)
    end
    expect { described_class.set_receive_only(transport_obj: handle, enabled: 'true') }.to raise_error(ArgumentError)
    expect { described_class.set_receive_only(transport_obj: handle, enabled: true, to: '!aabbccdd') }.to raise_error(ArgumentError, /local/)
    expect { described_class.set_receive_only(transport_obj: MQTTClient.new, enabled: true) }.to raise_error(ArgumentError, /local/)
    expect(handle[:written]).to be_empty
  end

  it 'prints usage without raising' do
    expect { described_class.help }.to output(/USAGE/).to_stdout
  end
end
